# OFFICESTRA macOS release

The public installer must be signed with a Developer ID Application
certificate and notarized by Apple. Ad-hoc artifacts are for local testing
only.

## One-time repository secrets

Configure these GitHub Actions secrets. Never commit their values.

- `APPLE_DEVELOPER_ID_P12_BASE64`
- `APPLE_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_CI_KEYCHAIN_PASSWORD`
- `APPLE_NOTARY_APPLE_ID`
- `APPLE_NOTARY_TEAM_ID`
- `APPLE_NOTARY_APP_PASSWORD`

The P12 secret is the base64 representation of a Developer ID Application
certificate and its private key. The notarization password must be an
app-specific password for the configured Apple ID.

## Publish

1. Set `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist`.
2. Merge a clean, passing commit into `main`.
3. Create and push the exact semantic tag, for example `v1.3.0` for app
   version `1.3.0`.
4. The `Release` workflow tests the repository, signs the nested Node runtime
   and app with hardened runtime, submits the app to Apple, staples and
   validates the ticket, creates ZIP and DMG artifacts, verifies checksums,
   and publishes the GitHub Release.

The workflow fetches `origin/main` and refuses a tag whose commit is not part
of that branch. It also scans the tagged sources before loading signing
credentials, scans the finished app again, recalculates the packaged backend
release identity, and launches both the notarized app and the copy mounted
from the final DMG. The launch smoke uses an isolated first-run home directory
and rejects early process exit or fatal runtime log messages.

For both architectures, the workflow also extracts the exact backend,
production dependencies, Compose file, migrations, and default configuration
from the signed app. An Ubuntu Docker gate then starts that packaged runtime
with a host Node of the supported major version and requires an isolated first
task to complete before the release can be published. The macOS job separately
executes and signature-checks the architecture-matching bundled Node. A local
maintainer check below joins both halves against the final DMG with Docker
Desktop and the bundled Node itself.

`OFFICESTRABackendReleaseID` is calculated from the files the packaged backend
actually reads: backend sources and package manifests, migrations, Compose,
the final `characters.json`, and stable Node metadata. Node is represented by
its pre-sign SHA-256, runtime version, signed CDHash, and verified minimal
entitlements so Apple secure timestamps do not make identical runtime inputs
look like different backend releases.

The workflow stops before publishing if the tag and app version differ, a
required secret is absent, signing or notarization fails, or an artifact does
not pass verification.

## Local packaging check

Without Apple credentials, maintainers can still test the bundle and package
layout:

```sh
./scripts/build-app.sh
python3 scripts/backend-release-id.py \
  --verify \
  --verify-node-signature \
  dist/OFFICESTRA.app
./scripts/smoke-test-macos-release.sh dist/OFFICESTRA.app
./scripts/package-release.sh
./scripts/test-packaged-community-preview-e2e.sh \
  "$(find dist/release -maxdepth 1 -name '*.dmg' -print -quit)"
```

The final command requires Docker Desktop to be running. It mounts the actual
DMG and uses only its bundled Node runtime, backend, Compose file, and database
migrations to initialize an isolated PostgreSQL volume and complete a fake
first agent task. It uses dedicated ports and removes the temporary container,
volume, process, and mount when the check finishes.

The resulting filenames explicitly contain `adhoc`; do not present those
files as public installers. With credentials already stored in the Keychain,
use `OFFICESTRA_CODESIGN_IDENTITY` while building and
`OFFICESTRA_NOTARY_PROFILE` with `scripts/notarize-app.sh` before packaging.
