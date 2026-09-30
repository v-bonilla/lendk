#!/usr/bin/env bats
# Repository rules: test/lint-repo.bash on the repository and on scratch copies with planted defects.
# Planted strings are assembled at run time so the repository never holds them.

setup() {
	load helpers/common
	sandbox
}

# scratch: copy the repository, without .git and the submodule, to $COPY.
scratch() {
	COPY=$SB/copy
	mkdir -p "$COPY"
	local f
	for f in "$ROOT"/* "$ROOT"/.[!.]*; do
		[[ ${f##*/} == .git ]] || cp -R "$f" "$COPY/"
	done
	rm -rf "$COPY/test/lib"
}

# lint_copy: run the lint on the scratch copy; it must fail with a line matching $1.
lint_copy() {
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$status" 1
	[[ $output == *$1* ]] || { printf 'no %q in:\n%s\n' "$1" "$output" >&2; return 1; }
}

@test "NFR9: the repository passes lint-repo.bash" {
	run bash "$ROOT/test/lint-repo.bash"
	assert_eq "$output" ""
	assert_eq "$status" 0
}

@test "NFR9: the unchanged scratch copy passes lint-repo.bash" {
	scratch
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	assert_eq "$status" 0
}

@test "NFR9: lint-repo.bash flags a planted em-dash" {
	scratch
	printf 'a %s b\n' "$(printf '\342\200\224')" >>"$COPY/docs/prd.md"
	lint_copy "docs/prd.md:"*": em-dash"
}

@test "NFR9: lint-repo.bash flags a planted email address" {
	scratch
	local at=@
	printf 'contact: alice%sexample.org\n' "$at" >>"$COPY/test/helpers/common.bash"
	lint_copy "test/helpers/common.bash:"*": email address"
}

@test "NFR9: lint-repo.bash flags a home path other than /home/alice and accepts /home/alice" {
	scratch
	local home=/ho
	printf 'ok: %s\n' "${home}me/alice/.local/bin/lend" >>"$COPY/Makefile"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$status" 0
	printf 'bad: %s\n' "${home}me/bob/.config" >>"$COPY/Makefile"
	lint_copy "Makefile:"*": home path other than /home/alice"
}

@test "NFR9: lint-repo.bash flags a license held by someone else" {
	scratch
	sed 's/v-bonilla/someone/' "$ROOT/LICENSE" >"$COPY/LICENSE"
	lint_copy "LICENSE: not MIT held by v-bonilla"
}

@test "NFR9: lint-repo.bash flags a PRD ID found neither in a test nor in pending-ids" {
	scratch
	printf -- '- %s%s Planted requirement.\n' FR 99 >>"$COPY/docs/prd.md"
	lint_copy "FR99: in no test name and not in test/pending-ids"
}

@test "NFR9: lint-repo.bash flags an ID both in a test name and in pending-ids" {
	scratch
	echo FR22 >>"$COPY/test/pending-ids"
	lint_copy "FR22: in a test name and in test/pending-ids"
}

@test "NFR9: lint-repo.bash flags a pending ID the PRD does not define" {
	scratch
	printf '%s%s\n' NFR 99 >>"$COPY/test/pending-ids"
	lint_copy "NFR99: not in docs/prd.md"
}

@test "NFR7: lint-repo.bash flags a second file in bin/" {
	scratch
	touch "$COPY/bin/helper"
	lint_copy "bin/: holds"
}

@test "NFR3: lint-repo.bash flags non-portable commands in bin/lend, except in the name-list tables" {
	scratch
	local w
	for w in stat 'readlink -f' timeout flock setsid 'sed -i' 'date +%N'; do
		cp "$ROOT/bin/lend" "$COPY/bin/lend"
		# shellcheck disable=SC2016
		printf 'x=$(%s /x)\n' "$w" >>"$COPY/bin/lend"
		lint_copy "non-portable command"
	done
	cp "$ROOT/bin/lend" "$COPY/bin/lend"
	printf '# lint: tables begin\ntimeout stat\n# lint: tables end\ntimeout=5\n' >>"$COPY/bin/lend"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	assert_eq "$status" 0
	# shellcheck disable=SC2016
	printf 'echo "${%s}"\n' EPOCHREALTIME >>"$COPY/bin/lend"
	lint_copy "bash 5 variable"
}

@test "NFR3: lint-repo.bash allows /proc and ps only in the terminal-owner test" {
	scratch
	printf '# lint: tty-owner begin\nread -r s </proc/$$/stat || ps -o tpgid=\n# lint: tty-owner end\n' >>"$COPY/bin/lend"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	printf 'ps -o pid=\n' >>"$COPY/bin/lend"
	lint_copy "/proc or ps outside the terminal-owner test"
}

@test "NFR3: lint-repo.bash flags script outside the test helpers" {
	scratch
	printf '%s -qc true /dev/null\n' script >>"$COPY/test/lint.bats"
	lint_copy "only test helpers may call script"
}

@test "NFR4: bats-core is the pinned submodule and shellcheck is pinned through uvx" {
	grep -qx '	url = https://github.com/bats-core/bats-core' "$ROOT/.gitmodules"
	run "$ROOT/test/lib/bats-core/bin/bats" --version
	assert_eq "$output" "Bats 1.14.0"
	grep -q '^SHELLCHECK := uvx --from shellcheck-py==0.11.0.1 shellcheck$' "$ROOT/Makefile"
}
