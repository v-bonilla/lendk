#!/usr/bin/env bash
# Repository lint: content rules, no reference to the retired spec or its FR, NFR and AC IDs, portability of bin/lendk, the network markers of the Rust source, one file in bin/.
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

# bin/ holds one file.
bins=(bin/*)
[[ ${#bins[@]} -eq 1 && ${bins[0]} == bin/lendk ]] || problem "bin/: holds ${bins[*]}, not only bin/lendk"

# Portability and network rules on bin/lendk, skipping the name-list tables, the terminal-owner test and the network region.
# cmdpos WORD [START]: WORD in command position; START matches the line start.
cmdpos() { printf '(%s|[;&|(]|[$][(])[[:space:]]*%s([^A-Za-z0-9_=-]|$)' "${2:-^}" "$1"; }
if [[ -f bin/lendk ]]; then
	body=$(awk '
		/# lint: tables begin/ { t = 1 } /# lint: tables end/ { t = 0; next }
		/# lint: tty-owner begin/ { o = 1 } /# lint: tty-owner end/ { o = 0; next }
		/^# lint: network begin$/ { n = (++regions == 1) } /^# lint: network end$/ { n = 0; next }
		/^backend_(has|read)\(\) \{/ { b = 1 }
		{ print (n ? "N" : (t ? "#" : (o ? "O" : (b ? "B" : " ")))) NR ":" $0 }
		b && /^\}/ { b = 0 }' bin/lendk)
	code=$(grep -v '^#' <<<"$body")
	start='^[ OBN][0-9]+:'
	# Only the backend functions name pass or the store.
	while IFS= read -r hit; do problem "bin/lendk:${hit:1}: pass or the store outside backend_has and backend_read"; done < <(
		grep -E -e "$(cmdpos pass '^[ ON][0-9]+:')|[\$][{]?store([^A-Za-z0-9_]|\$)" <<<"$code" | grep -v '^B')
	for word in stat 'readlink[[:space:]]+-f' timeout flock setsid 'sed[[:space:]]+-i' 'date[[:space:]]+[+]%N'; do
		while IFS= read -r hit; do problem "bin/lendk:${hit:1}: non-portable command"; done < <(grep -E -e "$(cmdpos "$word" "$start")" <<<"$code")
	done
	while IFS= read -r hit; do problem "bin/lendk:${hit:1}: bash 5 variable"; done < <(grep -E -e '[$](EPOCHREALTIME|SRANDOM)|[$][{](EPOCHREALTIME|SRANDOM)([^-]|$)' <<<"$code")
	# One network region, opened and closed once; comments and tables count too.
	[[ $(grep -c '^# lint: network begin$' bin/lendk) == 1 && $(grep -c '^# lint: network end$' bin/lendk) == 1 ]] ||
		problem "bin/lendk: not exactly one network region"
	while IFS= read -r hit; do problem "bin/lendk:${hit:1}: curl or wget outside the network region"; done < <(
		grep -E -e '[^A-Za-z0-9_-](curl|wget)([^A-Za-z0-9_-]|$)' <<<"$body" | grep -v '^N')
	while IFS= read -r hit; do problem "bin/lendk:${hit:1}: network tool"; done < <(
		{ grep -E -e "$(cmdpos nc "$start")" <<<"$code"; grep -E -e '/dev/(tcp|udp)' <<<"$body"; } | sort -u)
	while IFS= read -r hit; do problem "bin/lendk:${hit:1}: /proc or ps outside the terminal-owner test"; done < <(grep -E -e "/proc|$(cmdpos ps "$start")" <<<"$code" | grep -v '^O')
fi
# The Rust source names curl and wget only between the network markers (ADR 0013).
for f in "${files[@]}"; do
	[[ $f == src/*.rs ]] || continue
	while IFS= read -r hit; do problem "$f:$hit: curl or wget outside the network region"; done < <(awk '
		/^[[:space:]]*\/\/ lint: network begin$/ { n = 1 } /^[[:space:]]*\/\/ lint: network end$/ { n = 0; next }
		!n && /(^|[^A-Za-z0-9_-])(curl|wget)([^A-Za-z0-9_-]|$)/ { print NR }' "$f")
done
for f in "${files[@]}"; do
	[[ $f == bin/lendk || $f == test/*.bats || $f == test/fixtures/* ]] || continue
	while IFS= read -r hit; do problem "$f:$hit: only test helpers may call script"; done < <(grep -nE -e "$(cmdpos script)" -- "$f")
done

((problems == 0))
