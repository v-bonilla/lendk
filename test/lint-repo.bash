#!/usr/bin/env bash
# Repository lint: content rules, no reference to the retired spec or its FR, NFR and AC IDs, the network markers of the Rust source, script only in the test helpers.
# Usage: test/lint-repo.bash [ROOT]; prints one line per problem and exits 1 when there is any.
set -u -o pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$root" || exit 2
problems=0
problem() { printf 'lint-repo: %s\n' "$*"; problems=$((problems + 1)); }

# Ignored directories, the .gitignore lines ending in /, hold build output such as dist/, not repository files.
prune=(-name .git -o -path ./test/lib)
if [[ -f .gitignore ]]; then
	while IFS= read -r f; do
		[[ $f == */ && $f != *[*?[]* ]] && prune+=(-o -path "./${f%/}")
	done <.gitignore
fi
files=()
while IFS= read -r f; do files+=("${f#./}"); done < <(find . \( "${prune[@]}" \) -prune -o -type f -print | sort)

# No em-dashes, email addresses, home paths other than /home/alice, or real-looking keys.
# supply-chain/imports.lock alone may hold email addresses: cargo-vet copies each third-party auditor's into it.
emdash=$'\xe2\x80\x94'
while IFS= read -r hit; do problem "$hit: em-dash"; done < <(grep -nHF -e "$emdash" -- "${files[@]}")
while IFS= read -r hit; do
	[[ $hit == supply-chain/imports.lock:* ]] || problem "$hit: email address"
done < <(grep -nHE -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- "${files[@]}")
while IFS= read -r hit; do
	[[ ${hit#*:*:} =~ /(home|Users)/[A-Za-z0-9_.-]+ ]] || continue
	stripped=${hit#*:*:}
	stripped=${stripped//\/home\/alice/}
	[[ $stripped =~ /(home|Users)/[A-Za-z0-9_.-]+ ]] && problem "$hit: home path other than /home/alice"
done < <(grep -nHE -e '/(home|Users)/[A-Za-z0-9_.-]+' -- "${files[@]}")
while IFS= read -r hit; do problem "$hit: key-shaped value"; done < <(grep -nHE -e 'gh[pousr]_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{32,}' -- "${files[@]}")

# The spec retired into tests, ADRs and docs; H, A and G IDs are too short to match safely.
retired='docs/p''rd[.]md'
while IFS= read -r hit; do problem "$hit: retired spec reference"; done < <(grep -nHE -e "$retired" -- "${files[@]}")
while IFS= read -r hit; do problem "$hit: retired spec ID"; done < <(grep -nHE -e '(^|[^A-Za-z0-9_])(N?FR|AC)[0-9]+([^A-Za-z0-9_]|$)' -- "${files[@]}")
if ! grep -q '^MIT License' LICENSE 2>/dev/null || ! grep -q 'v-bonilla' LICENSE; then problem "LICENSE: not MIT held by v-bonilla"; fi

# The Rust source names curl and wget only in its one network region, and never nc or /dev/tcp (ADR 0013).
rs=()
for f in "${files[@]}"; do [[ $f == src/*.rs ]] && rs+=("$f"); done
if ((${#rs[@]})); then
	[[ $(cat -- "${rs[@]}" | grep -c '^[[:space:]]*// lint: network begin$') == 1 &&
		$(cat -- "${rs[@]}" | grep -c '^[[:space:]]*// lint: network end$') == 1 ]] ||
		problem "src: not exactly one network region"
	while IFS= read -r hit; do problem "$hit"; done < <(awk '
		/^[[:space:]]*\/\/ lint: network begin$/ { n = (++regions == 1) } /^[[:space:]]*\/\/ lint: network end$/ { n = 0; next }
		!n && /(^|[^A-Za-z0-9_-])(curl|wget)([^A-Za-z0-9_-]|$)/ { print FILENAME ":" FNR ": curl or wget outside the network region" }
		/(^|[^A-Za-z0-9_-])nc([^A-Za-z0-9_-]|$)|\/dev\/(tcp|udp)/ { print FILENAME ":" FNR ": network tool" }' "${rs[@]}")
fi
# cmdpos WORD: WORD in command position.
cmdpos() { printf '(^|[;&|(]|[$][(])[[:space:]]*%s([^A-Za-z0-9_=-]|$)' "$1"; }
for f in "${files[@]}"; do
	[[ $f == test/*.bats || $f == test/fixtures/* ]] || continue
	while IFS= read -r hit; do problem "$f:$hit: only test helpers may call script"; done < <(grep -nE -e "$(cmdpos script)" -- "$f")
done

((problems == 0))
