# OFFICESTRA macOS release

## Current channel: Community Preview

The current public release is deliberately ad-hoc signed and is not notarized
by Apple. GitHub must publish it as a **Pre-release**, every DMG and ZIP filename
must contain `adhoc`, and the Release page and both READMEs must warn users
before download. Users may either allow the single app through macOS **Open
Anyway** or build the tagged source themselves. Never recommend globally
disabling Gatekeeper or applying broad `xattr` commands.

## Publish an ad-hoc preview

1. Set `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist`.
2. Merge a clean, passing commit into `main` and wait for the main CI workflow.
3. Confirm that the semantic tag and GitHub Release do not already exist.
4. Create and push the exact semantic tag, for example `v1.3.0` for app version
   `1.3.0`.
5. Manually run `Community Preview Release` with that existing tag. The
   workflow builds ad-hoc arm64 and x86_64 apps, creates ZIP and DMG artifacts,
   verifies checksums, runs the packaged backend against Docker, and publishes
   a GitHub Pre-release only after every gate passes. Do not run `Notarized
   Release` for the same tag.

The workflow fetches `origin/main` and refuses a tag whose commit is not part
of that branch or whose name differs from the app version. It scans both the
tagged source and finished app for credentials and developer-local paths. It
also launches the app and the copy mounted from the final DMG in isolated
first-run homes, rejecting an early exit or fatal runtime log.

For both architectures, the workflow extracts the exact backend, production
dependencies, Compose file, migrations, and default configuration from the
packaged app. An Ubuntu Docker gate starts that packaged runtime with a host
Node of the supported major version and requires an isolated first task to
complete before publishing. This validates the package contents but cannot
simulate the quarantine attribute added by a real GitHub download; the
per-app **Open Anyway** step remains a documented manual action.

`OFFICESTRABackendReleaseID` is calculated from the files the packaged backend
actually reads: backend sources and package manifests, migrations, Compose,
the final `characters.json`, and stable Node metadata. Node is represented by
its pre-sign SHA-256, runtime version, signed CDHash, and verified minimal
entitlements.

Do not replace the files attached to an existing ad-hoc tag with notarized
files. A future notarized build must use a new semantic version so users can
tell exactly which security model they downloaded.

## Future Developer ID and notarized release

The separate `Notarized Release` workflow is manual and does not run when an
ordinary tag is pushed. Before using it, configure these GitHub Actions
secrets. Never commit their values.

- `APPLE_DEVELOPER_ID_P12_BASE64`
- `APPLE_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_CI_KEYCHAIN_PASSWORD`
- `APPLE_NOTARY_APPLE_ID`
- `APPLE_NOTARY_TEAM_ID`
- `APPLE_NOTARY_APP_PASSWORD`

The P12 secret is the base64 representation of a Developer ID Application
certificate and its private key. The notarization password must be an
app-specific password for the configured Apple ID. Create a new version tag,
then manually run `Notarized Release` with that existing tag. The workflow
imports the certificate, signs the nested Node runtime and app with hardened
runtime, submits both the app and DMG to Apple, staples and validates the
ticket, runs the same package and Docker gates, and publishes the Release.

## Local packaging check

Without Apple credentials, maintainers can test the ad-hoc bundle and package
layout locally:

```sh
./scripts/build-app.sh
python3 scripts/backend-release-id.py \
  --verify \
  --verify-node-signature \
  dist/OFFICESTRA.app
./scripts/smoke-test-macos-release.sh dist/OFFICESTRA.app
./scripts/package-release.sh
./scripts/test-packaged-community-preview-e2e.sh \
  "$(find dist/release -maxdepth 1 -name '*-adhoc.dmg' -print -quit)"
```

The final command requires Docker Desktop to be running. It mounts the actual
DMG and uses only its bundled Node runtime, backend, Compose file, and database
migrations to initialize an isolated PostgreSQL volume and complete a fake
first agent task. It uses dedicated ports and removes the temporary container,
volume, process, and mount when the check finishes.

The resulting filenames explicitly contain `adhoc`. They may be published only
as a clearly labeled Community Preview with the warning and per-app opening
instructions above. With credentials already stored in the Keychain, use
`OFFICESTRA_CODESIGN_IDENTITY` while building and
`OFFICESTRA_NOTARY_PROFILE` with `scripts/notarize-app.sh` before packaging.
