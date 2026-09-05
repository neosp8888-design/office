# OFFICESTRA source publishing policy

OFFICESTRA publishes source code from the default `main` branch only.

- Do not create version tags or GitHub Releases.
- Do not upload DMG files, runnable app ZIP files, or checksum manifests.
- GitHub's **Code → Download ZIP** is the supported archive download; it is a
  snapshot of source code, not a prebuilt application.
- Keep local app-building and packaging scripts as developer tools only. Do not
  attach their output to GitHub unless the user explicitly changes this policy.
- Documentation-only updates should modify only the requested documentation and
  should not trigger app packaging in GitHub Actions.

For an ordinary source update, validate the changed scope, commit it, and push
it to `main`. Users can download the new snapshot from **Code → Download ZIP**
or clone the repository without a tag:

```sh
git clone --depth 1 https://github.com/neosp8888-design/officestra.git
```

Historical release incident reports remain as records. They do not describe the
current distribution channel.
