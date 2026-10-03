# Releasing lendk

1. Set `LENDK_VERSION` in `bin/lendk` to the new version; `lendk --version` prints it.
2. In `CHANGELOG.md`, move the `Unreleased` entries under `## [X.Y.Z] - YYYY-MM-DD` with the release date, and update the comparison links.
3. Delete `docs/plan.md` when the release had one: no tag holds a plan.
4. Run the three gates; each must exit 0:
   ```
   make check
   make check-docker
   make bench
   ```
5. Commit on `dev`, merge `dev` into `main` with a pull request or a fast-forward push, and wait for the CI workflow to pass on `main`, every job, macOS included (AC6).
6. Check out the `main` commit that passed, create an annotated tag on it by name, and push the tag. A ruleset blocks deleting or moving a `v*` tag, so the tag names its commit:
   ```
   git fetch origin
   git checkout --detach origin/main
   git tag -a vX.Y.Z -m 'lendk X.Y.Z' origin/main
   git push origin vX.Y.Z
   ```
7. Build the release assets from the tagged commit: `make dist` writes `dist/lendk.tar.gz` (the git tree at HEAD under `lendk-X.Y.Z/`) and `dist/SHA256SUMS`.
8. Create the GitHub release for the tag with both assets, and the version's CHANGELOG entry as its notes. `install.sh` and `lendk upgrade` both read them from `releases/latest/download/`, so the release must not be a draft or a prerelease:
   ```
   gh release create vX.Y.Z --title 'lendk X.Y.Z' --notes-file NOTES.md dist/lendk.tar.gz dist/SHA256SUMS
   ```
9. Check the installer against the new release in a scratch HOME:
   ```
   scratch=$(mktemp -d)
   curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | HOME=$scratch bash -s -- --yes --no-modify-path
   ```
10. Check `lendk upgrade` against the new release, in the scratch HOME the installer filled. Run it in the same shell as step 9, since it reuses `$scratch`:
    ```
    HOME=$scratch "$scratch/.local/bin/lendk" upgrade
    ```
    It prints `lendk X.Y.Z is up to date: the latest release is X.Y.Z`. This is the only run of the real download path, since the suite stubs the download tools.
