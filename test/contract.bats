#!/usr/bin/env bats
# NFR8: --help carries every verb, list, class, FIX and variable the PRD defines.
# shellcheck disable=SC2016

setup() {
	load helpers/common
	sandbox
	PRD=$ROOT/docs/prd.md
	HELP=$("$LEND" --help)
}

# prd_list LABEL: the backticked list that follows LABEL in the PRD.
prd_list() {
	local line
	line=$(grep -oE "$1 \`[^\`]+\`" "$PRD" | head -n 1)
	[[ -n $line ]] || { echo "no list after '$1' in the PRD" >&2; return 1; }
	line=${line#*\`}
	printf '%s\n' "${line%\`}"
}

@test "NFR8: every verb line of PRD 4.1 is in --help" {
	local line n=0
	while IFS= read -r line; do
		assert_line "$HELP" "  ${line% (4.3)}"
		n=$((n + 1))
	done < <(sed -n '/^### 4.1 Verbs/,/^### 4.2/p' "$PRD" | sed -n '/^```$/,/^```$/p' | grep '^lend ')
	assert_eq "$n" 8
}

@test "NFR8: every name list of PRD 4.2 is in --help, word for word" {
	local pair
	for pair in "own runtime:|reserved commands" "prefixes|denied key prefixes" "names|denied key names" \
		"shells|guarded shells" "interpreters|guarded interpreters" "launchers|guarded launchers" \
		"package tools|guarded package tools" "agent CLIs|guarded agent CLIs"; do
		assert_line "$HELP" "  ${pair#*|}: $(prd_list "${pair%|*}")"
	done
}

@test "NFR8: every class of PRD 5.3 is in --help with its exit hint" {
	local class hint n=0
	while read -r class hint; do
		assert_line "$(grep -oE '^  [a-z-]+ \([0-9]+\)' <<<"$HELP")" "  $class $hint)"
		n=$((n + 1))
	done < <(sed -n '/^### 5.3/,/^## 6/p' "$PRD" | grep -oE '^- `[a-z-]+` \([0-9]+' | sed 's/^- //; s/`//g')
	assert_eq "$n" 15
}

@test "NFR8: every FIX of PRD 5.3, interactive and not, is in --help" {
	local fix n=0
	while IFS= read -r fix; do
		[[ $HELP == *"$fix"* ]] || { echo "missing FIX: $fix" >&2; return 1; }
		n=$((n + 1))
	done < <(sed -n '/^### 5.3/,/^## 6/p' "$PRD" | grep -oE '`(See|To map|Put|Upgrade|Run the|Retry;|Fix|Map it|Add it|Set it|Install|Ask the user|Stop and)[^`]*`' | tr -d '`')
	assert_eq "$n" 18
}

@test "NFR8: every variable of PRD section 8 is in --help" {
	local name n=0
	while read -r name; do
		assert_line "$(grep -oE '^  [A-Z_]+ ' <<<"$HELP" | sed 's/ *$//')" "  $name"
		n=$((n + 1))
	done < <(sed -n '/^## 8\./,/^## 9\./p' "$PRD" | grep -oE 'LEND_[A-Z_]+|PASSWORD_STORE_DIR|XDG_[A-Z_]+_HOME|GPG_TTY' | sort -u)
	assert_eq "$n" 10
}
