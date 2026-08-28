# Releasing Plandalf

Plandalf releases are produced by `.github/workflows/release.yml`.

## Version source of truth

`VERSION` is authoritative. A release tag must be exactly:

```text
v<VERSION>
```

For example, if `VERSION` contains `0.1.0`, the release tag must be `v0.1.0`.

The release workflow fails before building if the requested tag and `VERSION` do not match.

## Manual release from GitHub

Manual releases are intended to work from the GitHub website or mobile app without a local development machine.

1. Merge the release-preparation PR to `main`.
2. Open **Actions**.
3. Select **release**.
4. Choose **Run workflow**.
5. Select the `main` branch.
6. Enter the tag, for example `v0.1.0`.
7. Leave **prerelease** disabled for a stable release.
8. Run the workflow.

Manual release runs are rejected when dispatched from a branch other than `main`.

## Tag-driven release

Pushing a tag matching `v*` also starts the release workflow. The tag must still match `VERSION` exactly.

## Release targets

The workflow currently builds and smoke-tests:

```text
linux-x86_64
macos-aarch64
macos-x86_64
```

Windows is intentionally omitted until a native Windows CI build and smoke test are green.

## Release artifacts

Each release publishes three archives:

```text
plandalf-v<VERSION>-linux-x86_64.tar.gz
plandalf-v<VERSION>-macos-aarch64.tar.gz
plandalf-v<VERSION>-macos-x86_64.tar.gz
```

Each archive contains:

```text
plandalf
LICENSE
README.md
```

The release also includes `SHA256SUMS` covering all three archives.

## Build and smoke behavior

Every target uses Zig 0.16.0 and a `ReleaseFast` build. Before packaging, the workflow verifies that:

- `plandalf --help` executes successfully;
- a clean temporary home can create the default SQLite database through `plandalf decks`;
- the database is created beneath `.local/share/plandalf/plandalf.db`.

The normal CI workflow remains responsible for the complete test suite, `.deck` round-trip smoke, web/API smoke, formatting, and benchmark smoke before a release-preparation PR is merged.

## GitHub permissions

The workflow uses the repository-provided `GITHUB_TOKEN` with `contents: write` only for publishing the GitHub Release and tag. No external release secret is required.
