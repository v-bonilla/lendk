# Releasing lendk

1. Set `LENDK_VERSION` in `bin/lendk` to the new version; `lendk --version` prints it.
2. In `CHANGELOG.md`, move the `Unreleased` entries under `## [X.Y.Z] - YYYY-MM-DD` with the release date, and update the comparison links.
3. Run the three gates; each must exit 0:
   ```
   make check
   make check-docker
   make bench
   ```
4. Commit on `dev`, merge `dev` into `main` with a pull request or a fast-forward push, and wait for the CI workflow to pass on `main`, every job, macOS included (AC6).
5. Check out the `main` commit that passed, create an annotated tag on it by name, and push the tag. A ruleset blocks deleting or moving a `v*` tag, so the tag names its commit:
   ```
   git fetch origin
   git checkout --detach origin/main
   git tag -a vX.Y.Z -m 'lendk X.Y.Z' origin/main
   git push origin vX.Y.Z
   ```
6. Build the release assets from the tagged commit: `make dist` writes `dist/lendk.tar.gz` (the git tree at HEAD under `lendk-X.Y.Z/`) and `dist/SHA256SUMS`.
7. Create the GitHub release for the tag with both assets, and the version's CHANGELOG entry as its notes. `install.sh` downloads them through `releases/latest/download/`, so the release must not be a draft or a prerelease:
   ```
   gh release create vX.Y.Z --title 'lendk X.Y.Z' --notes-file NOTES.md dist/lendk.tar.gz dist/SHA256SUMS
   ```
8. Check the installer against the new release in a scratch HOME:
   ```
   curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | HOME=$(mktemp -d) bash -s -- --yes --no-modify-path
   ```
