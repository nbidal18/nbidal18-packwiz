# Tool provenance

Recorded on 2026-08-10. The binaries live under the git-ignored `tools/` directory and are not published with the update site.

## packwiz-installer-bootstrap

- Upstream: <https://github.com/packwiz/packwiz-installer-bootstrap>
- Release: `v0.0.3`
- Asset: <https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar>
- Local path: `tools/packwiz-installer-bootstrap.jar`
- Size: `98,989` bytes
- SHA-256: `A8FBB24DC604278E97F4688E82D3D91A318B98EFC08D5DBFCBCBCAB6443D116C`

This JAR is copied into the final Prism migration ZIP and invokes the Packwiz installer before Minecraft starts.

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
