# Prototype for #41: reproducible musl builds and musl's shrink realloc

Throwaway. This branch never merges.

- `src/main.rs`: a lendk-shaped binary linking `age = "=0.12.1"` with no feature, `libc` and `zeroize`.
- `src/bin/probe.rs`: a global allocator that, on each shrinking realloc during an age decrypt, checks whether the block moved and scans the old block for the plaintext through `/proc/self/mem`.
- `build.sh TARGET OUTDIR`: the release build command under test.
- `host.sh a|b`: builds both targets in a container standing in for a host. `a` is Debian 13, root, `/root`, `/src/lendk`. `b` is Ubuntu 24.04, uid 1500, `/home/alice`, `/home/alice/w/deep/build-dir`, TZ Asia/Tokyo, umask 077.
- `.github/workflows/proto-41-reproducible.yml`: the native arm64 leg, for GitHub's runners.

Run: `SOURCE_DATE_EPOCH=1792429677 ./host.sh a`, then `./host.sh b`, then `sha256sum out/*/*/*`.

Results: `out/` is ignored; the ticket's closing comment holds them.
