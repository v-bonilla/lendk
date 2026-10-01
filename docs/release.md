# Releasing lendk

1. Set `LENDK_VERSION` in `bin/lendk` to the new version; `lendk --version` prints it.
2. In `CHANGELOG.md`, move the `Unreleased` entries under `## [X.Y.Z] - YYYY-MM-DD` with the release date, and update the comparison links.
3. Run the three gates; each must exit 0:
   ```
   make check
   make check-docker
   make bench
   ```
4. First release only: create the GitHub repository `v-bonilla/lendk` as private, push `main`, and wait for the CI workflow to pass. Making the repository public needs the maintainer's approval.
5. Commit, then create an annotated tag and push it:
   ```
   git tag -a vX.Y.Z -m 'lendk X.Y.Z'
   git push origin main vX.Y.Z
   ```
6. Create the GitHub release for the tag, with the version's CHANGELOG entry as its notes:
   ```
   gh release create vX.Y.Z --title 'lendk X.Y.Z' --notes-file NOTES.md
   ```
