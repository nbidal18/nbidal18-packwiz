# nbidal18 launch guard

This MIT-licensed Java 21 pre-launch program makes Packwiz validate the pack on
every launch and then applies the pack's strict-content policy. It has no
third-party runtime dependencies.

Pack URLs must use HTTPS. Plain HTTP is accepted only for isolated tests whose
URI host is exactly `localhost`, an unambiguous dotted-decimal address in
`127.0.0.0/8`, or literal IPv6 loopback. URL userinfo, deceptive hostname
suffixes, and non-loopback HTTP are rejected before Packwiz runs.

## Manifest protocol (TSV v1)

The Packwiz index must install `.nbidal18/strict-manifest.tsv` as UTF-8 text.
Blank lines and lines beginning with `#` are ignored. Paths always use `/`, are
relative to the Minecraft directory, and may not traverse, be absolute, or use
links/reparse points.

```text
nbidal18-strict-manifest\t1
strict-dir\tmods
managed\t<sha256>\tmods/example.jar
optional\t<sha256>\tdatapacks/Still_Life-1.0-beta1.zip
personal\tconfig/controlify.json
runtime\tconfig/example-runtime-state.json
runtime-prefix\tconfig/example-runtime-cache
seed\t.nbidal18/defaults/options.txt\toptions.txt
regenerate-prefix\tshaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3
```

- `strict-dir` declares a directory whose contents are exact-cleaned.
- `managed` declares a required regular file and its SHA-256. A seed template
  outside a strict directory must also be declared as managed.
- `optional` declares an exact private file: absence is allowed, but a present
  file with the wrong hash is quarantined.
- `personal` and `runtime` declare exact unhashed files inside strict directories.
  `runtime-prefix` declares an exact runtime-owned subtree that is preserved.
- `seed` copies a managed template only when the player target does not exist.
  Seed targets are preserved thereafter. The guard applies the pack's narrow
  mixed-setting policies to `options.txt`, `config/iris.properties`, and
  `config/controlify.json` without resetting unrelated player settings.
- `regenerate-prefix` declares a generated directory inside a strict directory.
  Any pre-launch copy is safely deleted without following links or placing the
  generated files in quarantine, so the trusted mod recreates it from the exact
  managed inputs after attestation.

Unauthorized content is moved without following links to
`.nbidal18/quarantine/<timestamp>-<uuid>/`. On success the guard atomically
writes `.nbidal18/integrity-attestation.tsv`:

```text
nbidal18-integrity-attestation\t1
manifest-sha256\t<sha256>
verified-at-utc\t<ISO-8601 UTC instant>
```

Immediately before attestation, the guard permanently removes only the
generated Fabric cache roots `.fabric/processedMods`, `.fabric/remappedJars`,
and `.fabric/tmp`, plus Moonlight's top-level
`dynamic-resource-pack-cache`. It preserves all other roots and `.fabric`
content, never follows a link/reparse node while purging, and blocks launch if
`.fabric` itself is not a plain directory inside the Minecraft root. Generated
caches are not copied to quarantine, so normal launches do not accumulate cache
backups.

## Build

From PowerShell, with a Java 21+ JDK available through `-JavaHome`, `JAVA_HOME`,
or `PATH`:

```powershell
.\build.ps1
```

The script compiles with `javac --release 21`, creates two fixed-timestamp JARs,
compares their SHA-256 values, and publishes the identical result as
`../../tools/nbidal18-launch-guard.jar`.

The guard is bundled by the thin Prism migration builder. Existing Prism
instances whose pre-launch command directly invokes Packwiz are not modified in
place and must be reimported to adopt strict launch enforcement. Once the guard
is installed, it temporarily backs up currently declared seed targets before
the normal Packwiz pass, so a still-declared player setting survives a later
manifest transition that removes or relocates its old Packwiz entry.

## Same-launch guard upgrades

Version 1.1.0 keeps the manifest protocol at v1 and adds a backwards-compatible
self-handoff. A candidate is considered only after the normal and forced
Packwiz passes agree on the strict manifest and the complete strict policy has
cleaned and hash-verified every managed file. The running guard then locates the
single manifest-managed `mods/nbidal18-pack-compat-*.jar`, verifies its exact
manifest SHA-256 again, and reads its bounded embedded guard payload and
descriptor. A locally forged manifest or companion that survives only the
normal Packwiz fast path can therefore never reach Java execution.
If that reviewed payload differs from the running artifact, it is staged under
an immutable hash name and executed as a child Java process after the parent
releases its instance lock. A fresh hash- and nonce-bound one-shot request must
then be consumed by that exact candidate under the same instance lock; command
line properties alone cannot authorize a handoff. The candidate reruns the
complete two-pass policy, and its exact exit code becomes the pre-launch exit
code. A one-generation depth limit fails closed on a recursive chain. After the
child exits, a zero exit code is accepted only if the one-shot request has been
consumed and the parent can parse a fresh exact attestation matching the guard,
companion, and forced-validated manifest hashes. It then verifies and removes
its exact candidate staging file. The running/main JAR is never overwritten,
which keeps the handoff safe on Windows.

After a successful candidate run, `.nbidal18/launch-guard-handoff.tsv` binds the
fresh result to the guard, companion, and strict-manifest hashes. The companion
can consume this bounded marker after atomically installing that same guard and
avoid an unnecessary game restart. For the one-time migration from an older
guard, `.nbidal18/prism-relaunch.tsv` is a short-lived, nonce-bound request: the
new guard acknowledges it under the launch lock only when its own hash and
Prism's exact `INST_ID` match. The waiting helper consumes that acknowledgement;
malformed, stale, or mismatched armed requests are discarded.
