#!/usr/bin/env bats
# --help keeps every 1.x verb, name list, class, FIX and variable of test/frozen, and sync writes the frozen shim.
# shellcheck disable=SC2016

setup() {
	load helpers/common
	sandbox
	FROZEN=$ROOT/test/frozen
	HELP=$("$LENDK" --help)
}

# frozen_missing HELP: prints each frozen entry that HELP lacks; a list word missing from its list counts.
frozen_missing() {
	local help=$1 entry label word words
	local -A have
	while IFS= read -r entry; do
		[[ $'\n'$help$'\n' == *$'\n'"  $entry"[$' \n']* ]] || printf 'verb: %s\n' "$entry"
	done <"$FROZEN/verbs"
	while IFS= read -r entry; do
		label=${entry%%: *}
		words=$(grep -m 1 "^  $label: " <<<"$help")
		have=()
		for word in ${words#*: }; do have[$word]=1; done
		for word in ${entry#*: }; do
			[[ -n ${have[$word]-} ]] || printf 'list word: %s %s\n' "$label" "$word"
		done
	done <"$FROZEN/lists"
	while IFS= read -r entry; do
		[[ $'\n'$help == *$'\n'"  $entry"* ]] || printf 'class: %s\n' "$entry"
	done <"$FROZEN/classes"
	while IFS= read -r entry; do
		[[ $help == *"$entry"* ]] || printf 'fix: %s\n' "$entry"
	done <"$FROZEN/fixes"
	while IFS= read -r entry; do
		grep -qE "^  $entry " <<<"$help" || printf 'variable: %s\n' "$entry"
	done <"$FROZEN/variables"
}

@test "--help carries every frozen verb, list word, class, FIX and variable" {
	assert_eq "$(frozen_missing "$HELP")" ""
}

@test "a renamed or removed entry fails the comparison while an added one or a changed verb description passes" {
	local added=${HELP/guarded shells: /guarded shells: newsh }
	added+=$'\n'"  lendk newverb"$'\n'"  newclass (3): new"$'\n'"  LENDK_NEW  new"
	assert_eq "$(frozen_missing "$added")" ""
	assert_eq "$(frozen_missing "${HELP/ dash / dashx }")" "list word: guarded shells dash"
	assert_eq "$(frozen_missing "${HELP/ zsh / }")" "list word: guarded shells zsh"
	assert_eq "$(frozen_missing "${HELP/  lendk sync/  lendk resync}")" "verb: lendk sync"
	assert_eq "$(frozen_missing "${HELP/\# map, then sync/\# map the names, then sync}")" ""
	assert_eq "$(frozen_missing "${HELP/lendk add [--force]/lendk add [-f]}")" "verb: lendk add [--force] CMD|@GROUP KEY|@GROUP..."
	assert_eq "$(frozen_missing "${HELP/  locked (120)/  held (120)}")" "class: locked (120)"
	assert_eq "$(frozen_missing "${HELP/  LENDK_TIMEOUT /  LENDK_WAIT }")" "variable: LENDK_TIMEOUT"
	local fix
	fix=$(head -n 1 "$FROZEN/fixes")
	assert_eq "$(frozen_missing "${HELP//"$fix"/x}")" "fix: $fix"
}

@test "the README's name lists and classes are the lines --help prints" {
	local readme want got
	readme=$(<"$ROOT/README.md")
	want=$(sed -n '/^Name lists:/,/^$/p; /^Classes:/,/^$/p' <<<"$HELP" | grep -E '^  [a-z]' | grep -v '^  notice:')
	got=$(grep -E '^  ((reserved|denied|guarded) [a-zA-Z ]+: |[a-z-]+ \([0-9]+\): )' <<<"$readme")
	assert_eq "$(sort <<<"$got")" "$(sort <<<"$want")"
	assert_eq "$(wc -l <<<"$want")" 31
}

@test "sync writes the frozen shim text" {
	local want
	want=$(<"$FROZEN/shim")
	want=${want//\/home\/alice\/.local\/bin\/lendk/$LENDK}
	want=${want//so gh did/so stub did}
	want=${want//"'gh'"/"'stub'"}
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf 'stub K1\n' >"$HOME/.config/lendk/map" && chmod 600 "$HOME/.config/lendk/map"
	LENDK_SHIMS=$SB/shims run_lendk sync
	assert_eq "$status" 0
	assert_eq "$(cat "$SB/shims/stub")" "$want"
}

@test "--help is byte for byte the help of the frozen 1.x lendk" {
	"$LENDK" --help >"$SB/help"
	bash "$FIXTURES/lendk-1.x" --help >"$SB/help.1x"
	cmp "$SB/help.1x" "$SB/help"
}
