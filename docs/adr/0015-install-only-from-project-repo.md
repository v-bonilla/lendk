# Install only from the project repository

lendk reads every mapped key, so where its one file comes from is the root of its trust. lendk installs only from the project repository: `install.sh`, which fetches a release from the project's GitHub releases, or `make install` from a checkout. No package of it exists in a registry, and no lendk message points anyone to one. A registry name belongs to whoever claimed it, so a package that carries lendk's name can be anyone's code, and an agent told to install lendk from a registry could fetch a stranger's program that then sees every key.

## Considered Options

- Packages in npm, PyPI, crates.io, Homebrew or a distribution: each adds a publisher and a copy to trust, under a name someone else may hold. A package manager would also own the installed file, which `lendk upgrade` refuses to replace ([ADR 0014](0014-upgrade-trusts-https-release-replaces-one-file.md)). Packaging beyond `make install` is not a goal.

## Consequences

- The `lendk-missing` FIX, which a shim prints for every caller when lendk is gone, tells the human to reinstall lendk from its project repository.
- `run_lendk` in `test/helpers/common.bash` fails any test whose non-interactive stderr names npm, cargo, `pip install` or brew.
- `install.sh` and `lendk upgrade` read the same release assets, so both trust the same source.
