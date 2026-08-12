# nbidal18 v3.2.7 Packwiz validation report

- Result: PASS
- Started: 2026-08-12 16:22:42 +02:00
- Completed: 2026-08-12 16:23:14 +02:00
- Packwiz site files: 504
- Exact Modrinth-managed archives: 225 (210 mods, 12 resource packs, 1 datapack, 2 shader packs)
- Reviewed internal-hosted archives: 13 (9 mods, 2 resource packs, 2 datapacks, 0 shader packs)
- Hosted datapack allowlist entries: 2
- Migration-only external files in the public manifest: 0

Validated:

- Packwiz refresh is reproducible and the checked-in manifest is current.
- Still Life, raw shader archives/sidecars, seed targets, Controlify state, Iris state, VinURL helpers, voice state, runtime caches, fingerprints, and warnings are absent from the public index; only reviewed seed templates are published.
- The six-file thin migration ZIP contains only Prism metadata/icon, the Packwiz bootstrap, and the exact reviewed launch-guard JAR; it contains no Packwiz-managed payload, VinURL data, Still Life, shaders, or player state.
- The first guarded launch performs both Packwiz passes, cold-installs and hash-verifies every managed payload, seeds absent settings once, and writes an attestation matching the installed strict manifest.
- Generated Fabric nested/remapped-mod caches and Moonlight's loadable dynamic resource-pack cache are purged before attestation, while unrelated .fabric state remains byte-preserved.
- Mixed settings are narrowed without resetting unrelated preferences: options.txt receives canonical resource-pack lines, Iris rejects unknown shaders while retaining the exact generated Euphoria selection, and Controlify reach-around is forced off.
- The managed companion contains the exact reviewed launch guard. The exact published v3.2.4 guard artifact (SHA-256 63243A6972BF4B89C0E2DDE79B48F20009781C021AA68D30DCB19063AECCAC45) is atomically replaced through the production client updater without changing Prism metadata/bootstrap files; a second updater call is a true no-op, and the following guarded launch preserves the generated Euphoria selection.
- A production package-private one-click harness proves the v3.2.4 replacement chooses relaunch, round-trips the exact Prism executable/root/game/instance/PID/start-time/nonce helper request, consumes one matching acknowledgement, and refuses every UP_TO_DATE or already-handed-off restart decision. A fresh exact guard/companion/manifest handoff proof is consumed and suppresses relaunch; stale and guard-mismatched proofs remain untrusted.
- The launch-guard producer smoke separately executes a byte-distinct, identity-valid next guard as a child in the same pre-launch, checks exact child-exit propagation, one-generation depth enforcement, immutable hash-named staging, malformed-descriptor rejection, and the exact hash-bound handoff-attestation and Prism-marker schemas. This is an isolated JVM test, not a real Prism process handoff.
- Unknown mod, resource-pack, shader, datapack, Moonlight global-datapack, Villager API pack, server-pack cache, retired CustomSkinLoader runtime/core/cache/plugin/provider, and config canaries are absent from strict roots and remain recoverable under .nbidal18/quarantine; the disposable Euphoria-generated shader tree is purged and rebuilt instead of accumulating in quarantine.
- Exact optional Still Life, saves, screenshots, Skin Overrides skin/cape selections and libraries, VinURL data, approved shader sidecar settings, JEI/runtime state, and seed-once settings persist byte-for-byte.
- An unchanged release still performs the normal and forced Packwiz passes. The forced pass repairs the sole tampered managed canary, downloads no other managed payload, quarantines a newly added extra, and refreshes a matching attestation.
- A later release adds and removes JAR-named managed-file canaries in mods/, overwrites a managed config, updates the strict manifest, and attests the new manifest.
- The changed release reports exactly the added mod, changed config, and strict-manifest downloads plus the one expected managed deletion.
- A deliberately unavailable payload produces a clear nonzero failure, retains the previous Packwiz state, demonstrates the known partial write, leaves no attestation, and is repaired and re-attested by the next successful release.

External release gates are outside this isolated behavior report. Build-Release.ps1 separately requires the anonymous HTTPS pack.toml, index.toml, strict manifest, and every reviewed internal-hosted payload to match before it produces the final ZIP. Reaching the Minecraft menu, confirming that a failed pre-launch command blocks Minecraft, and production multiplayer compatibility remain manual checks.

Historical 3.1.0 -> 3.1.1 transition: the old direct-Packwiz Prism instance could not acquire the nbidal18 launch-guard JAR or Prism pre-launch command through Packwiz, so that cutover required a one-time import of the 3.1.1 six-file migration ZIP. Existing runnable guarded instances receive 3.2.7 and companion 1.1.11 in place. Version 3.2.5 bridged to launch guard 1.1.0 through a controlled exact-instance Prism relaunch; version 3.2.6 fixed its Windows child-output pipe deadlock by disconnecting all three standard streams. Version 3.2.7 retains that path and adds the consolidated Auto HUD integration. The companion regression floods both stdout and stderr beyond pipe capacity, requires the exact acknowledgment, and completes without changing the validated Prism arguments or bounded retries. Later guard updates self-handoff during pre-launch. Missing/corrupt guards and command/filename changes still require the recovery ZIP. The isolated behavior test verifies the embedded guard migration and next guarded launch; a real Prism process handoff remains a final end-to-end release check.

Known limitation: Packwiz is not transaction-wide atomic. In the deliberate failure test, an available managed config was written before a later payload returned 404, although player-controlled/runtime files and the previous Packwiz state remained intact. The guard removed the stale attestation immediately, and the next successful pre-launch run repaired and attested the managed release. Final Prism testing must confirm a nonzero pre-launch result blocks Minecraft from starting.
