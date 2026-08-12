# Tool provenance

The standalone binaries live under the git-ignored `tools/` directory and are never indexed as Packwiz-managed files. The reviewed launch-guard bytes are also embedded inside the internally hosted pack-compat companion. Version 3.2.5 introduced the bridge to guard 1.1.0; version 3.2.6 companion 1.1.10 fixes the detached Prism child's output-pipe deadlock while retaining the exact reviewed guard bytes. Guard 1.1.0 can self-handoff later embedded guard updates during pre-launch.

## packwiz-installer-bootstrap

- Upstream: <https://github.com/packwiz/packwiz-installer-bootstrap>
- Release: `v0.0.3`
- Asset: <https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar>
- Local path: `tools/packwiz-installer-bootstrap.jar`
- Size: `98,989` bytes
- SHA-256: `A8FBB24DC604278E97F4688E82D3D91A318B98EFC08D5DBFCBCBCAB6443D116C`

This JAR is copied into the final Prism migration ZIP and invokes the Packwiz installer before Minecraft starts.

## nbidal18 launch guard

- License: first-party MIT
- Source: `source/nbidal18-launch-guard/`
- Local path: `tools/nbidal18-launch-guard.jar`
- Release: `1.1.0`
- Size: `65,406` bytes
- SHA-256: `7BE9B87B00B92307A2F9B830C6D5FB2E5D74D583E5AB9FF3A9779AB7FF8FA79A`

The reproducible Java 21 build compiles twice with fixed archive timestamps and requires byte-identical output. The final Prism migration ZIP runs this guard, which invokes Packwiz, exact-cleans strict content, verifies SHA-256 values, applies the narrow settings policy, purges generated loadable Fabric/Moonlight caches, and writes the runtime attestation before Minecraft starts.

## Packwiz CLI

- Upstream: <https://github.com/packwiz/packwiz>
- Successful official Actions run: <https://github.com/packwiz/packwiz/actions/runs/28793198419>
- Run commit: `dfd8b68a4796c763e25bad50265ea1f1233e24f1`
- Windows 64-bit artifact ID: `8109648450`
- Anonymous artifact mirror used: <https://nightly.link/packwiz/packwiz/actions/artifacts/8109648450.zip>
- Downloaded ZIP SHA-256: `9754292DCA00C833BDD9B8D3DDF60B5EE01065CCAFDEBB0E708E18C9C0C5098C`
- Local executable: `tools/packwiz-current/packwiz.exe`
- Executable SHA-256: `7182F0B513A4FF117CA252B7EAEA2CEDEEDE19DD9A0BED77A10403D75A3C9295`

The CLI generated and refreshed `site/index.toml`, served the isolated local test site, and was used to prove reproducible manifests. GitHub Actions artifacts expire, so a future maintainer should select a new successful official Windows build and record its run, commit, and hashes before replacing the executable.
