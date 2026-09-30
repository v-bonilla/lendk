#!/usr/bin/env bash
# Repository lint: NFR9 content rules, portability of bin/lend (R9), one file in bin/, PRD ID coverage.
# Usage: test/lint-repo.bash [ROOT]; prints one line per problem and exits 1 when there is any.
set -u -o pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$root" || exit 2
problems=0
problem() { printf 'lint-repo: %s\n' "$*"; problems=$((problems + 1)); }

files=()
while IFS= read -r f; do files+=("${f#./}"); done < <(find . \( -name .git -o -path ./test/lib \) -prune -o -type f -print | sort)

# NFR9: no em-dashes, email addresses, home paths other than /home/alice, or real-looking keys.
emdash=$'\xe2\x80\x94'
while IFS= read -r hit; do problem "$hit: em-dash"; done < <(grep -nHF -e "$emdash" -- "${files[@]}")
while IFS= read -r hit; do problem "$hit: email address"; done < <(grep -nHE -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- "${files[@]}")
while IFS= read -r hit; do
	[[ ${hit#*:*:} =~ /(home|Users)/[A-Za-z0-9_.-]+ ]] || continue
	stripped=${hit#*:*:}
	stripped=${stripped//\/home\/alice/}
	[[ $stripped =~ /(home|Users)/[A-Za-z0-9_.-]+ ]] && problem "$hit: home path other than /home/alice"
done < <(grep -nHE -e '/(home|Users)/[A-Za-z0-9_.-]+' -- "${files[@]}")
while IFS= read -r hit; do problem "$hit: key-shaped value"; done < <(grep -nHE -e 'gh[pousr]_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{32,}' -- "${files[@]}")
if ! grep -q '^MIT License' LICENSE 2>/dev/null || ! grep -q 'v-bonilla' LICENSE; then problem "LICENSE: not MIT held by v-bonilla"; fi

# NFR7: bin/ holds one file.
bins=(bin/*)
[[ ${#bins[@]} -eq 1 && ${bins[0]} == bin/lend ]] || problem "bin/: holds ${bins[*]}, not only bin/lend"

# R9 on bin/lend, skipping the name-list tables and the terminal-owner test.
# cmdpos WORD [START]: WORD in command position; START matches the line start.
cmdpos() { printf '(%s|[;&|(]|[$][(])[[:space:]]*%s([^A-Za-z0-9_-]|$)' "${2:-^}" "$1"; }
if [[ -f bin/lend ]]; then
	body=$(awk '
		/# lint: tables begin/ { t = 1 } /# lint: tables end/ { t = 0; next }
		/# lint: tty-owner begin/ { o = 1 } /# lint: tty-owner end/ { o = 0; next }
		{ print (t ? "#" : (o ? "O" : " ")) NR ":" $0 }' bin/lend)
	code=$(grep -v '^#' <<<"$body")
	start='^[ O][0-9]+:'
	for word in stat 'readlink[[:space:]]+-f' timeout flock setsid 'sed[[:space:]]+-i' 'date[[:space:]]+[+]%N'; do
		while IFS= read -r hit; do problem "bin/lend:${hit:1}: non-portable command"; done < <(grep -E -e "$(cmdpos "$word" "$start")" <<<"$code")
	done
	while IFS= read -r hit; do problem "bin/lend:${hit:1}: bash 5 variable"; done < <(grep -E -e '[$][{]?(EPOCHREALTIME|SRANDOM)' <<<"$code")
	while IFS= read -r hit; do problem "bin/lend:${hit:1}: /proc or ps outside the terminal-owner test"; done < <(grep -E -e "/proc|$(cmdpos ps "$start")" <<<"$code" | grep -v '^O')
fi
for f in "${files[@]}"; do
	[[ $f == bin/lend || $f == test/*.bats || $f == test/fixtures/* ]] || continue
	while IFS= read -r hit; do problem "$f:$hit: only test helpers may call script"; done < <(grep -nE -e "$(cmdpos script)" -- "$f")
done

# PRD ID coverage: each FR and NFR ID sits in a test name or in test/pending-ids, never both.
declare -A in_prd=() in_test=() in_pending=()
while read -r _ id _; do in_prd[$id]=1; done < <(grep -E '^- N?FR[0-9]+ ' docs/prd.md 2>/dev/null)
for f in test/*.bats; do
	[[ -f $f ]] || continue
	while IFS= read -r name; do
		name=${name#*@test [\"\']}
		while read -r id; do in_test[$id]=1; done < <(grep -oE 'N?FR[0-9]+' <<<"${name%%:*}")
	done < <(grep -E '^[[:space:]]*@test ["'\''](N?FR[0-9]+(, )?)+:' "$f")
done
if [[ -f test/pending-ids ]]; then
	while read -r id; do [[ -n $id ]] && in_pending[$id]=1; done <test/pending-ids
fi
for id in "${!in_prd[@]}"; do
	[[ -n ${in_test[$id]-} && -n ${in_pending[$id]-} ]] && problem "$id: in a test name and in test/pending-ids"
	[[ -z ${in_test[$id]-} && -z ${in_pending[$id]-} ]] && problem "$id: in no test name and not in test/pending-ids"
done
for id in "${!in_test[@]}" "${!in_pending[@]}"; do
	[[ -n ${in_prd[$id]-} ]] || problem "$id: not in docs/prd.md"
done

((problems == 0))
