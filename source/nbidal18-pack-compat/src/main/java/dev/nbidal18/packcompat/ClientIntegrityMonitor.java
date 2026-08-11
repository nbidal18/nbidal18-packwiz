package dev.nbidal18.packcompat;

import net.minecraft.client.Minecraft;
import net.minecraft.network.Connection;
import net.minecraft.network.chat.Component;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardWatchEventKinds;
import java.nio.file.WatchEvent;
import java.nio.file.WatchKey;
import java.nio.file.WatchService;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.Clock;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

final class ClientIntegrityMonitor implements AutoCloseable {
    private static final Logger LOGGER = LoggerFactory.getLogger("nbidal18-pack-compat");
    private static final long METADATA_SCAN_NANOS = 15_000_000_000L;
    private static final long SETTINGS_SCAN_NANOS = 10_000_000_000L;
    private static final long FULL_SCAN_NANOS = 300_000_000_000L;
    static final Path DYNAMIC_RESOURCE_CACHE_ROOT = Path.of("dynamic-resource-pack-cache");

    private final Path gameDirectory;
    private final StrictManifest manifest;
    private final IntegrityVerifier verifier;
    private final RuntimeSettingsVerifier settingsVerifier;
    private final FabricCacheVerifier fabricCacheVerifier;
    private final FabricCacheVerifier.CacheBaseline fabricCacheBaseline;
    private final ClosedEmptyRootVerifier closedEmptyRootVerifier;
    private final GeneratedTreePins generatedTreePins;
    private final ExecutorService worker;
    private final WatchService watchService;
    private final Object watchLock = new Object();
    private final Map<WatchKey, Path> watchDirectories = new HashMap<>();
    private final Set<String> watchedDirectoryKeys = new HashSet<>();
    private final Object regenerationLock = new Object();
    private final Map<String, RegenerationState> regenerationStates = new LinkedHashMap<>();
    private final AtomicBoolean fullScanRequested = new AtomicBoolean();
    private final AtomicBoolean metadataScanRequested = new AtomicBoolean();
    private final AtomicBoolean settingsScanRequested = new AtomicBoolean();
    private final AtomicBoolean workerRunning = new AtomicBoolean();
    private final Object dynamicCacheLock = new Object();

    private volatile LoginIntegrityState loginState;
    private volatile Map<String, IntegrityVerifier.FileFingerprint> fingerprints;
    private volatile Map<String, IntegrityVerifier.RegeneratedTree> regeneratedTrees = Map.of();
    private volatile FabricCacheVerifier.CacheRoot dynamicResourceCacheBaseline;
    private DynamicCachePhase dynamicCachePhase = DynamicCachePhase.WAITING;
    private volatile boolean clientLifecycleStarted;
    private volatile boolean generatedRootsFinalizationStarted;
    private volatile boolean closed;
    private long nextMetadataScan;
    private long nextSettingsScan;
    private long nextFullScan;
    private Connection lastDisconnectedConnection;

    static ClientIntegrityMonitor initialize(Path gameDirectory) {
        return initialize(gameDirectory, Clock.systemUTC(), GeneratedTreePins.reviewed(), false);
    }

    static ClientIntegrityMonitor initialize(Path gameDirectory, boolean customSkinLoaderPresent) {
        return initialize(
                gameDirectory,
                Clock.systemUTC(),
                GeneratedTreePins.reviewed(),
                customSkinLoaderPresent
        );
    }

    static ClientIntegrityMonitor initialize(Path gameDirectory, Clock clock) {
        return initialize(gameDirectory, clock, GeneratedTreePins.reviewed(), false);
    }

    static ClientIntegrityMonitor initialize(
            Path gameDirectory,
            Clock clock,
            GeneratedTreePins generatedTreePins
    ) {
        return initialize(gameDirectory, clock, generatedTreePins, false);
    }

    static ClientIntegrityMonitor initialize(
            Path gameDirectory,
            Clock clock,
            GeneratedTreePins generatedTreePins,
            boolean customSkinLoaderPresent
    ) {
        Path normalized;
        try {
            normalized = StrictManifest.normalizedRoot(gameDirectory);
        } catch (IntegrityException invalidRoot) {
            return failedFallback(gameDirectory, invalidRoot.getMessage());
        }

        StrictManifest manifest = null;
        try {
            manifest = StrictManifest.load(normalized);
            IntegrityAttestation.loadAndValidate(normalized, manifest.sha256(), clock);
            IntegrityVerifier verifier = new IntegrityVerifier(normalized);
            // Re-hash loadable managed content before reporting clean. This closes the narrow
            // guard-process to game-JVM race even when a path is replaced with identical metadata.
            // A declared regenerate-prefix may already have been created by an earlier client
            // initializer, so it remains explicitly uncaptured/pending until post-reload pinning.
            IntegrityVerifier.VerificationResult verification = verifier.verifyFull(manifest, Map.of(), true);
            if (!verification.clean()) {
                throw new IntegrityException(verification.message());
            }
            RuntimeSettingsVerifier settingsVerifier = new RuntimeSettingsVerifier(normalized);
            RuntimeSettingsVerifier.SettingsResult settings = settingsVerifier.verify(manifest);
            if (!settings.clean()) {
                throw new IntegrityException(settings.message());
            }
            FabricCacheVerifier fabricCacheVerifier = new FabricCacheVerifier(
                    normalized,
                    customSkinLoaderPresent
            );
            FabricCacheVerifier.CacheBaseline fabricCacheBaseline = fabricCacheVerifier.capture();
            ClosedEmptyRootVerifier closedEmptyRootVerifier = new ClosedEmptyRootVerifier(normalized);
            ClosedEmptyRootVerifier.VerificationResult closedRoot = closedEmptyRootVerifier.verify();
            if (!closedRoot.clean()) {
                throw new IntegrityException(closedRoot.message());
            }
            return new ClientIntegrityMonitor(
                    normalized,
                    manifest,
                    verifier,
                    settingsVerifier,
                    fabricCacheVerifier,
                    fabricCacheBaseline,
                    closedEmptyRootVerifier,
                    generatedTreePins,
                    verification.fingerprints(),
                    new LoginIntegrityState(true, manifest.sha256(), "clean")
            );
        } catch (IOException | IntegrityException | RuntimeException failure) {
            String digest = manifest == null ? "" : manifest.sha256();
            String message = safeMessage(failure);
            LOGGER.warn("nbidal18 integrity initialization failed: {}", message);
            return new ClientIntegrityMonitor(
                    normalized,
                    manifest,
                    null,
                    null,
                    null,
                    null,
                    null,
                    generatedTreePins,
                    Map.of(),
                    new LoginIntegrityState(false, digest, message)
            );
        }
    }

    private static ClientIntegrityMonitor failedFallback(Path gameDirectory, String message) {
        Path safeRoot = gameDirectory == null
                ? Path.of(".").toAbsolutePath().normalize()
                : gameDirectory.toAbsolutePath().normalize();
        return new ClientIntegrityMonitor(
                safeRoot,
                null,
                null,
                null,
                null,
                null,
                null,
                GeneratedTreePins.reviewed(),
                Map.of(),
                new LoginIntegrityState(false, "", message)
        );
    }

    private ClientIntegrityMonitor(
            Path gameDirectory,
            StrictManifest manifest,
            IntegrityVerifier verifier,
            RuntimeSettingsVerifier settingsVerifier,
            FabricCacheVerifier fabricCacheVerifier,
            FabricCacheVerifier.CacheBaseline fabricCacheBaseline,
            ClosedEmptyRootVerifier closedEmptyRootVerifier,
            GeneratedTreePins generatedTreePins,
            Map<String, IntegrityVerifier.FileFingerprint> fingerprints,
            LoginIntegrityState initialState
    ) {
        this.gameDirectory = gameDirectory;
        this.manifest = manifest;
        this.verifier = verifier;
        this.settingsVerifier = settingsVerifier;
        this.fabricCacheVerifier = fabricCacheVerifier;
        this.fabricCacheBaseline = fabricCacheBaseline;
        this.closedEmptyRootVerifier = closedEmptyRootVerifier;
        this.generatedTreePins = generatedTreePins;
        this.fingerprints = fingerprints;
        this.loginState = initialState;
        this.worker = Executors.newSingleThreadExecutor(task -> {
            Thread thread = new Thread(task, "nbidal18-integrity-monitor");
            thread.setDaemon(true);
            return thread;
        });

        WatchService watcher = null;
        if (initialState.clean() && manifest != null) {
            synchronized (regenerationLock) {
                for (Path prefix : manifest.regeneratePrefixes()) {
                    regenerationStates.put(StrictManifest.key(prefix), new RegenerationState(prefix));
                }
            }
            try {
                watcher = gameDirectory.getFileSystem().newWatchService();
            } catch (IOException ignored) {
                // Periodic metadata and hash scans remain active if native watching is unavailable.
            }
        }
        this.watchService = watcher;
        if (watchService != null) {
            try {
                registerInitialWatches();
            } catch (IOException ignored) {
                // A later full scan remains the fail-closed source of truth.
            }
        }
        long now = System.nanoTime();
        nextMetadataScan = now + METADATA_SCAN_NANOS;
        nextSettingsScan = now + SETTINGS_SCAN_NANOS;
        nextFullScan = now + FULL_SCAN_NANOS;
    }

    LoginIntegrityState loginState() {
        LoginIntegrityState current = loginState;
        if (!current.clean()) {
            return current;
        }
        if (!clientLifecycleStarted) {
            return new LoginIntegrityState(
                    false,
                    current.manifestSha256(),
                    "generated-cache verification is still pending until client startup completes"
            );
        }
        if (!generatedRootsFinalizationStarted) {
            return new LoginIntegrityState(
                    false,
                    current.manifestSha256(),
                    "generated-cache verification is still pending until initial resource loading completes"
            );
        }
        synchronized (dynamicCacheLock) {
            if (dynamicCachePhase != DynamicCachePhase.LOCKED) {
                return new LoginIntegrityState(
                        false,
                        current.manifestSha256(),
                        "dynamic-resource-pack-cache verification is still pending"
                );
            }
        }
        synchronized (regenerationLock) {
            if (regenerationStates.values().stream()
                    .anyMatch(state -> state.phase == RegenerationPhase.PENDING)) {
                return new LoginIntegrityState(
                        false,
                        current.manifestSha256(),
                        "generated shader verification is still pending"
                );
            }
        }
        return current;
    }

    void clientStarted() {
        if (closed || clientLifecycleStarted || !loginState.clean()) {
            return;
        }
        clientLifecycleStarted = true;
        LOGGER.info("nbidal18 integrity is waiting for initial resource loading to complete");
    }

    void tick(Minecraft client) {
        if (closed) {
            return;
        }
        long now = System.nanoTime();
        pollWatchEvents(now);
        advanceStartupFinalization(client.isGameLoadFinished());

        if (loginState.clean()) {
            if (now >= nextMetadataScan) {
                nextMetadataScan = now + METADATA_SCAN_NANOS;
                metadataScanRequested.set(true);
                startWorker();
            }
            if (now >= nextSettingsScan) {
                nextSettingsScan = now + SETTINGS_SCAN_NANOS;
                settingsScanRequested.set(true);
                startWorker();
            }
            if (now >= nextFullScan) {
                nextFullScan = now + FULL_SCAN_NANOS;
                fullScanRequested.set(true);
                startWorker();
            }
        }
        disconnectIfDirty(client);
    }

    void advanceStartupFinalization(boolean initialResourceLoadingComplete) {
        if (closed
                || !clientLifecycleStarted
                || generatedRootsFinalizationStarted
                || !initialResourceLoadingComplete
                || !loginState.clean()) {
            return;
        }

        // Consume writes from initial resource generation while they are still exempt. The
        // boundary is established immediately afterward, so every subsequently observed write
        // in a generated root remains a sticky integrity failure, including writes queued while
        // the synchronous capture and exact verification are running.
        pollWatchEvents(System.nanoTime());
        if (!loginState.clean()) {
            return;
        }
        generatedRootsFinalizationStarted = true;
        LOGGER.info("nbidal18 integrity is finalizing generated content after initial resource loading");
        finalizeGeneratedRoots();
        if (loginState.clean()) {
            // Consume anything queued while synchronous capture/hash verification was running
            // before a protocol query can observe a clean, locked state.
            pollWatchEvents(System.nanoTime());
        }
    }

    private void pollWatchEvents(long now) {
        if (watchService == null || manifest == null || !loginState.clean()) {
            return;
        }
        while (true) {
            WatchKey key = watchService.poll();
            if (key == null) {
                break;
            }
            Path watchedDirectory;
            synchronized (watchLock) {
                watchedDirectory = watchDirectories.get(key);
            }
            if (watchedDirectory == null) {
                key.reset();
                continue;
            }

            boolean overflow = false;
            for (WatchEvent<?> event : key.pollEvents()) {
                if (event.kind() == StandardWatchEventKinds.OVERFLOW) {
                    overflow = true;
                    continue;
                }
                if (!(event.context() instanceof Path context)) {
                    overflow = true;
                    continue;
                }
                Path changed = watchedDirectory.resolve(context).toAbsolutePath().normalize();
                handleChangedPath(changed, now);
                if (event.kind() == StandardWatchEventKinds.ENTRY_CREATE
                        && Files.isDirectory(changed, LinkOption.NOFOLLOW_LINKS)) {
                    try {
                        registerRecursively(changed);
                    } catch (IOException ignored) {
                        fullScanRequested.set(true);
                    }
                }
            }
            if (!key.reset()) {
                synchronized (watchLock) {
                    Path removed = watchDirectories.remove(key);
                    if (removed != null) {
                        watchedDirectoryKeys.remove(removed.toString().toLowerCase(java.util.Locale.ROOT));
                    }
                }
                overflow = true;
            }
            if (overflow) {
                handleWatchOverflow(watchedDirectory);
            }
        }
        if (fullScanRequested.get() || settingsScanRequested.get()) {
            startWorker();
        }
    }

    private void handleWatchOverflow(Path watchedDirectory) {
        if (!watchedDirectory.startsWith(gameDirectory)) {
            markDirty("Managed-content watcher overflowed outside the game directory");
            return;
        }
        Path relative = gameDirectory.relativize(watchedDirectory);
        if (fabricCacheVerifier.contains(relative) || closedEmptyRootVerifier.contains(relative)) {
            markDirty("A protected generated-cache/content watcher overflowed");
            return;
        }
        if (StrictManifest.withinOrEqual(DYNAMIC_RESOURCE_CACHE_ROOT, relative)) {
            if (generatedRootsFinalizationStarted) {
                markDirty("The dynamic resource-cache watcher overflowed after startup finalization");
            }
            return;
        }
        if (insideRuntimeStrictDirectory(relative)) {
            markDirty("A managed loadable-content watcher overflowed");
            return;
        }
        fullScanRequested.set(true);
    }

    void handleChangedPath(Path changed, long now) {
        if (!changed.startsWith(gameDirectory)) {
            markDirty("A watched managed path escaped the game directory");
            return;
        }
        Path relative = gameDirectory.relativize(changed);
        if (closedEmptyRootVerifier.contains(relative)) {
            markDirty("A closed empty loadable-content root changed after initialization: "
                    + StrictManifest.portable(relative));
            return;
        }
        if (fabricCacheVerifier.contains(relative)) {
            markDirty("Protected generated executable cache changed after its trusted baseline was captured: "
                    + StrictManifest.portable(relative));
            return;
        }
        if (StrictManifest.withinOrEqual(DYNAMIC_RESOURCE_CACHE_ROOT, relative)) {
            if (generatedRootsFinalizationStarted) {
                markDirty("dynamic-resource-pack-cache changed after startup finalization: "
                        + StrictManifest.portable(relative));
            }
            return;
        }
        if (isSecuritySettingsPath(relative)) {
            settingsScanRequested.set(true);
        }
        if (StrictManifest.key(relative).equals(StrictManifest.key(StrictManifest.RELATIVE_PATH))) {
            markDirty("The strict manifest changed after initialization");
            return;
        }

        Path regeneratePrefix = containingPrefix(relative, manifest.regeneratePrefixes());
        if (regeneratePrefix != null) {
            if (generatedRootsFinalizationStarted) {
                markDirty("Generated shader content changed after startup finalization: "
                        + StrictManifest.portable(relative));
            }
            return;
        }
        if (containingPrefix(relative, manifest.runtimePrefixes()) != null) {
            return;
        }
        if (isImmediateStrictViolation(relative)) {
            markDirty("Managed loadable content changed after initialization: "
                    + StrictManifest.portable(relative));
        }
    }

    private void finalizeGeneratedRoots() {
        try {
            FabricCacheVerifier.CacheRoot dynamicCache = fabricCacheVerifier.captureRequiredNonEmptyRoot(
                    DYNAMIC_RESOURCE_CACHE_ROOT
            );
            GeneratedTreePins.Validation dynamicPin = generatedTreePins.validateDynamicResourceCache(dynamicCache);
            if (!dynamicPin.clean()) {
                throw new IntegrityException(dynamicPin.message());
            }

            Map<String, IntegrityVerifier.RegeneratedTree> capturedRegeneration = new LinkedHashMap<>();
            synchronized (regenerationLock) {
                for (Map.Entry<String, RegenerationState> entry : regenerationStates.entrySet()) {
                    RegenerationState state = entry.getValue();
                    Path absolute = gameDirectory.resolve(state.prefix).normalize();
                    if (!Files.exists(absolute, LinkOption.NOFOLLOW_LINKS)) {
                        continue;
                    }
                    IntegrityVerifier.RegeneratedTree captured = verifier.captureRegeneratedTree(state.prefix);
                    GeneratedTreePins.Validation pin = generatedTreePins.validateEuphoria(captured);
                    if (!pin.clean()) {
                        throw new IntegrityException(pin.message());
                    }
                    capturedRegeneration.put(entry.getKey(), captured);
                }
            }

            // These roots commonly did not exist when the initial watches were registered.
            // Register their completed startup trees before the final exact verification so
            // post-boundary nested changes produce immediate events instead of relying only on
            // the periodic fallback scans.
            if (watchService != null) {
                registerRecursively(gameDirectory.resolve(DYNAMIC_RESOURCE_CACHE_ROOT));
                for (IntegrityVerifier.RegeneratedTree tree : capturedRegeneration.values()) {
                    registerRecursively(gameDirectory.resolve(tree.relativePrefix()));
                }
            }

            IntegrityVerifier.VerificationResult managed = verifier.verifyFull(
                    manifest,
                    capturedRegeneration,
                    false
            );
            if (!managed.clean()) {
                throw new IntegrityException(managed.message());
            }
            FabricCacheVerifier.VerificationResult dynamicVerified =
                    fabricCacheVerifier.verifyRootFull(dynamicCache);
            if (!dynamicVerified.clean()) {
                throw new IntegrityException(dynamicVerified.message());
            }

            regeneratedTrees = Collections.unmodifiableMap(new LinkedHashMap<>(capturedRegeneration));
            fingerprints = managed.fingerprints();
            synchronized (regenerationLock) {
                for (Map.Entry<String, RegenerationState> entry : regenerationStates.entrySet()) {
                    entry.getValue().phase = capturedRegeneration.containsKey(entry.getKey())
                            ? RegenerationPhase.LOCKED
                            : RegenerationPhase.FINAL_ABSENT;
                }
            }
            synchronized (dynamicCacheLock) {
                dynamicResourceCacheBaseline = dynamicCache;
                dynamicCachePhase = DynamicCachePhase.LOCKED;
            }
            LOGGER.info("nbidal18 integrity locked generated content for manifest {}", manifest.sha256());
        } catch (IOException | IntegrityException | RuntimeException failure) {
            markDirty(safeMessage(failure));
        }
    }

    private void startWorker() {
        if (closed || !loginState.clean() || verifier == null) {
            return;
        }
        if (workerRunning.compareAndSet(false, true)) {
            worker.execute(this::drainWork);
        }
    }

    private void drainWork() {
        try {
            while (!closed && loginState.clean()) {
                boolean full = fullScanRequested.getAndSet(false);
                boolean metadata = metadataScanRequested.getAndSet(false);
                boolean settings = settingsScanRequested.getAndSet(false);
                if (!full && !metadata && !settings) {
                    break;
                }
                if (full) {
                    runFullScan();
                } else if (metadata) {
                    runMetadataScan();
                }
                if (settings && loginState.clean()) {
                    runSettingsScan();
                }
            }
        } finally {
            workerRunning.set(false);
            if (!closed && loginState.clean() && hasPendingWork()) {
                startWorker();
            }
        }
    }

    void runFullScan() {
        ClosedEmptyRootVerifier.VerificationResult closedRoot = closedEmptyRootVerifier.verify();
        if (!closedRoot.clean()) {
            markDirty(closedRoot.message());
            return;
        }
        FabricCacheVerifier.VerificationResult cache = fabricCacheVerifier.verifyFull(fabricCacheBaseline);
        if (!cache.clean()) {
            markDirty(cache.message());
            return;
        }
        FabricCacheVerifier.CacheRoot dynamicBaseline = lockedDynamicResourceCacheBaseline();
        if (dynamicBaseline != null) {
            FabricCacheVerifier.VerificationResult dynamicCache =
                    fabricCacheVerifier.verifyRootFull(dynamicBaseline);
            if (!dynamicCache.clean()) {
                markDirty(dynamicCache.message());
                return;
            }
        }
        IntegrityVerifier.VerificationResult result = verifier.verifyFull(
                manifest,
                regeneratedTrees,
                false
        );
        if (!result.clean()) {
            markDirty(result.message());
            return;
        }
        fingerprints = result.fingerprints();
        runSettingsScan();
    }

    private void runMetadataScan() {
        ClosedEmptyRootVerifier.VerificationResult closedRoot = closedEmptyRootVerifier.verify();
        if (!closedRoot.clean()) {
            markDirty(closedRoot.message());
            return;
        }
        FabricCacheVerifier.VerificationResult cache = fabricCacheVerifier.verifyMetadata(fabricCacheBaseline);
        if (!cache.clean()) {
            markDirty(cache.message());
            return;
        }
        FabricCacheVerifier.CacheRoot dynamicBaseline = lockedDynamicResourceCacheBaseline();
        if (dynamicBaseline != null) {
            FabricCacheVerifier.VerificationResult dynamicCache =
                    fabricCacheVerifier.verifyRootMetadata(dynamicBaseline);
            if (!dynamicCache.clean()) {
                markDirty(dynamicCache.message());
                return;
            }
        }
        IntegrityVerifier.VerificationResult result = verifier.verifyIncremental(
                manifest,
                regeneratedTrees,
                false,
                fingerprints,
                Set.of()
        );
        if (!result.clean()) {
            markDirty(result.message());
            return;
        }
        fingerprints = result.fingerprints();
    }

    private void runSettingsScan() {
        RuntimeSettingsVerifier.SettingsResult result = settingsVerifier.verify(manifest);
        if (!result.clean()) {
            markDirty(result.message());
        }
    }

    private FabricCacheVerifier.CacheRoot lockedDynamicResourceCacheBaseline() {
        synchronized (dynamicCacheLock) {
            return dynamicCachePhase == DynamicCachePhase.LOCKED
                    ? dynamicResourceCacheBaseline
                    : null;
        }
    }

    private boolean hasPendingWork() {
        return fullScanRequested.get() || metadataScanRequested.get() || settingsScanRequested.get();
    }

    private void markDirty(String reason) {
        LoginIntegrityState current = loginState;
        if (current.clean()) {
            loginState = new LoginIntegrityState(false, current.manifestSha256(), reason);
            LOGGER.warn("nbidal18 integrity marked dirty: {}", reason);
        }
    }

    private void disconnectIfDirty(Minecraft client) {
        LoginIntegrityState state = loginState;
        if (state.clean() || client.getConnection() == null) {
            return;
        }
        Connection connection = client.getConnection().getConnection();
        if (connection == lastDisconnectedConnection) {
            return;
        }
        lastDisconnectedConnection = connection;
        connection.disconnect(Component.literal(
                "nbidal18 integrity check failed: " + state.message()
                        + ". Close Minecraft and relaunch through Prism so the guard can repair managed files."
        ));
    }

    private void registerInitialWatches() throws IOException {
        registerDirectory(gameDirectory);
        registerDirectory(gameDirectory.resolve("config"));
        registerDirectory(gameDirectory.resolve(".nbidal18"));
        registerDirectory(gameDirectory.resolve(".nbidal18").resolve("defaults"));
        registerDirectory(gameDirectory.resolve(".fabric"));
        for (Path cacheRoot : FabricCacheVerifier.RELATIVE_ROOTS) {
            registerRecursively(gameDirectory.resolve(cacheRoot));
        }
        registerRecursively(gameDirectory.resolve(DYNAMIC_RESOURCE_CACHE_ROOT));
        for (Path closedRoot : ClosedEmptyRootVerifier.RELATIVE_ROOTS) {
            registerRecursively(gameDirectory.resolve(closedRoot));
        }
        for (Path strict : manifest.strictDirectories()) {
            if (IntegrityVerifier.runtimeMonitored(strict)) {
                registerRecursively(gameDirectory.resolve(strict));
            }
        }
    }

    private void registerRecursively(Path root) throws IOException {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) {
            return;
        }
        Files.walkFileTree(root, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes)
                    throws IOException {
                Path normalized = directory.toAbsolutePath().normalize();
                if (!normalized.startsWith(gameDirectory) || attributes.isSymbolicLink()) {
                    return FileVisitResult.SKIP_SUBTREE;
                }
                Path relative = gameDirectory.relativize(normalized);
                Path runtimePrefix = containingPrefix(relative, manifest.runtimePrefixes());
                if (runtimePrefix != null
                        && StrictManifest.key(relative).equals(StrictManifest.key(runtimePrefix))) {
                    return FileVisitResult.SKIP_SUBTREE;
                }
                registerDirectory(normalized);
                return FileVisitResult.CONTINUE;
            }
        });
    }

    private void registerDirectory(Path directory) throws IOException {
        if (watchService == null || !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) {
            return;
        }
        Path normalized = directory.toAbsolutePath().normalize();
        String directoryKey = normalized.toString().toLowerCase(java.util.Locale.ROOT);
        synchronized (watchLock) {
            if (!watchedDirectoryKeys.add(directoryKey)) {
                return;
            }
            WatchKey key = normalized.register(
                    watchService,
                    StandardWatchEventKinds.ENTRY_CREATE,
                    StandardWatchEventKinds.ENTRY_DELETE,
                    StandardWatchEventKinds.ENTRY_MODIFY
            );
            watchDirectories.put(key, normalized);
        }
    }

    private boolean isSecuritySettingsPath(Path relative) {
        String key = StrictManifest.key(relative);
        if (key.equals(StrictManifest.key(RuntimeSettingsVerifier.OPTIONS))
                || key.equals(StrictManifest.key(RuntimeSettingsVerifier.IRIS))
                || key.equals(StrictManifest.key(RuntimeSettingsVerifier.CONTROLIFY))) {
            return true;
        }
        for (StrictManifest.SeedRule seed : manifest.seeds()) {
            if (key.equals(StrictManifest.key(seed.template()))) {
                return true;
            }
        }
        return false;
    }

    private boolean insideRuntimeStrictDirectory(Path relative) {
        for (Path strict : manifest.strictDirectories()) {
            if (IntegrityVerifier.runtimeMonitored(strict)
                    && StrictManifest.withinOrEqual(strict, relative)) {
                return true;
            }
        }
        return false;
    }

    private boolean isDeclaredMutableFile(Path relative) {
        String key = StrictManifest.key(relative);
        if (manifest.personalFilesByKey().containsKey(key)
                || manifest.runtimeFilesByKey().containsKey(key)) {
            return true;
        }
        for (StrictManifest.SeedRule seed : manifest.seeds()) {
            if (StrictManifest.key(seed.target()).equals(key)) {
                return true;
            }
        }
        return false;
    }

    boolean isImmediateStrictViolation(Path relative) {
        return containingPrefix(relative, manifest.regeneratePrefixes()) == null
                && containingPrefix(relative, manifest.runtimePrefixes()) == null
                && !isDeclaredMutableFile(relative)
                && insideRuntimeStrictDirectory(relative);
    }

    private static Path containingPrefix(Path relative, List<Path> prefixes) {
        for (Path prefix : prefixes) {
            if (StrictManifest.withinOrEqual(prefix, relative)) {
                return prefix;
            }
        }
        return null;
    }

    private static String safeMessage(Throwable failure) {
        String message = failure.getMessage();
        return message == null || message.isBlank() ? "Integrity verification failed" : message;
    }

    @Override
    public void close() {
        closed = true;
        worker.shutdownNow();
        if (watchService != null) {
            try {
                watchService.close();
            } catch (IOException ignored) {
            }
        }
    }

    record LoginIntegrityState(boolean clean, String manifestSha256, String message) {
    }

    private enum RegenerationPhase {
        PENDING,
        FINAL_ABSENT,
        LOCKED
    }

    private enum DynamicCachePhase {
        WAITING,
        LOCKED
    }

    private static final class RegenerationState {
        private final Path prefix;
        private RegenerationPhase phase = RegenerationPhase.PENDING;

        private RegenerationState(Path prefix) {
            this.prefix = prefix;
        }
    }
}
