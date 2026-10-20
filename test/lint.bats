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
		[[ ${f##*/} == @(.git|target|.tools) ]] || cp -R "$f" "$COPY/"
	done
	rm -rf "$COPY/test/lib"
}

# lint_copy: run the lint on the scratch copy; it must fail with a line matching $1.
lint_copy() {
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$status" 1
	[[ $output == *$1* ]] || { printf 'no %q in:\n%s\n' "$1" "$output" >&2; return 1; }
}

@test "the repository passes lint-repo.bash" {
	run bash "$ROOT/test/lint-repo.bash"
	assert_eq "$output" ""
	assert_eq "$status" 0
}

@test "the unchanged scratch copy passes lint-repo.bash" {
	scratch
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	assert_eq "$status" 0
}

@test "lint-repo.bash skips gitignored build output such as dist/" {
	scratch
	mkdir -p "$COPY/dist"
	printf 'built %s\n' $'\xe2\x80\x94' >"$COPY/dist/lendk.tar.gz"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	assert_eq "$status" 0
}

@test "lint-repo.bash flags a planted em-dash" {
	scratch
	printf 'a %s b\n' "$(printf '\342\200\224')" >>"$COPY/README.md"
	lint_copy "README.md:"*": em-dash"
}

@test "lint-repo.bash flags a planted reference to the retired spec" {
	scratch
	local spec=docs/p
	printf 'see %s\n' "${spec}rd.md" >>"$COPY/CHANGELOG.md"
	lint_copy "CHANGELOG.md:"*": retired spec reference"
}

@test "lint-repo.bash flags planted FR, NFR and AC IDs and accepts H, A and G IDs" {
	scratch
	local id ids=(F NF A)
	printf 'H1, A2 and G3 stay\n' >>"$COPY/GLOSSARY.md"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	ids=("${ids[0]}R24" "${ids[1]}R8" "${ids[2]}C5")
	for id in "${ids[@]}"; do
		scratch
		printf 'per %s.\n' "$id" >>"$COPY/docs/release.md"
		lint_copy "docs/release.md:"*"per $id"*": retired spec ID"
	done
}

@test "lint-repo.bash flags a planted email address" {
	scratch
	local at=@
	printf 'contact: alice%sexample.org\n' "$at" >>"$COPY/test/helpers/common.bash"
	lint_copy "test/helpers/common.bash:"*": email address"
}

@test "lint-repo.bash skips the email rule in supply-chain/imports.lock only, and every other rule covers it" {
	scratch
	local at=@
	printf 'who = "Alice <alice%sexample.org>"\n' "$at" >>"$COPY/supply-chain/imports.lock"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$output" ""
	assert_eq "$status" 0
	printf 'notes = "see %sme/bob/x"\n' /ho >>"$COPY/supply-chain/imports.lock"
	lint_copy "supply-chain/imports.lock:"*": home path other than /home/alice"
	printf 'who = "Alice <alice%sexample.org>"\n' "$at" >>"$COPY/supply-chain/audits.toml"
	lint_copy "supply-chain/audits.toml:"*": email address"
}

@test "lint-repo.bash flags a home path other than /home/alice and accepts /home/alice" {
	scratch
	local home=/ho
	printf 'ok: %s\n' "${home}me/alice/.local/bin/lendk" >>"$COPY/Makefile"
	run bash "$ROOT/test/lint-repo.bash" "$COPY"
	assert_eq "$status" 0
	printf 'bad: %s\n' "${home}me/bob/.config" >>"$COPY/Makefile"
	lint_copy "Makefile:"*": home path other than /home/alice"
}

@test "lint-repo.bash flags a license held by someone else" {
	scratch
	sed 's/v-bonilla/someone/' "$ROOT/LICENSE" >"$COPY/LICENSE"
	lint_copy "LICENSE: not MIT held by v-bonilla"
}

@test "lint-repo.bash allows curl and wget in the Rust source only between the network markers" {
	scratch
	local tool
	for tool in curl wget; do
		printf '// lint: network begin\nconst TOOL: &str = "%s";\n// lint: network end\n' "$tool" >>"$COPY/src/main.rs"
		run bash "$ROOT/test/lint-repo.bash" "$COPY"
		assert_eq "$output" ""
		printf 'const OTHER: &str = "%s";\n' "$tool" >>"$COPY/src/main.rs"
		lint_copy "src/main.rs:"
		assert_eq "$output" "lint-repo: src/main.rs:$(wc -l <"$COPY/src/main.rs"): curl or wget outside the network region"
		cp "$ROOT/src/main.rs" "$COPY/src/main.rs"
	done
}

@test "lint-repo.bash flags script outside the test helpers" {
	scratch
	printf '%s -qc true /dev/null\n' script >>"$COPY/test/lint.bats"
	lint_copy "only test helpers may call script"
}

@test "bats-core is the pinned submodule and shellcheck is pinned through uvx" {
	grep -qx '	url = https://github.com/bats-core/bats-core' "$ROOT/.gitmodules"
	run "$ROOT/test/lib/bats-core/bin/bats" --version
	assert_eq "$output" "Bats 1.14.0"
	grep -q '^SHELLCHECK := uvx --from shellcheck-py==0.11.0.1 shellcheck$' "$ROOT/Makefile"
}
