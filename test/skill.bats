#!/usr/bin/env bats
# FR38: the agent skill is a valid Agent Skill, and its verbs, classes and options match bin/lendk and install.sh.
# shellcheck disable=SC2013,SC2016

setup() {
	load helpers/common
	sandbox
	SKILL=$ROOT/skills/lendk/SKILL.md
	SETUP=$ROOT/skills/lendk/references/setup.md
	HELP=$("$LENDK" --help)
}

# classes_of FILE: the classes in FILE's table rows, sorted.
classes_of() { grep -oE '^\| `[a-z-]+` \|' "$1" | sed 's/^| `//; s/` |$//' | sort; }

@test "FR38: SKILL.md has Agent Skills frontmatter naming lendk, and stays concise" {
	assert_eq "$(sed -n 1p "$SKILL")" '---'
	local front
	front=$(sed -n '2,/^---$/p' "$SKILL")
	assert_line "$front" 'name: lendk'
	grep -qE '^description: Use when .{40,}' <<<"$front"
	(($(wc -l <"$SKILL") <= 250))
}

@test "FR38: the skill's verbs and classes are the ones lendk --help prints" {
	local want got verb
	want=$(grep -oE '^  lendk [a-z]+' <<<"$HELP" | awk '{ print $2 }' | sort -u)
	got=$(grep -ohE '(^|`)lendk [a-z]+' "$SKILL" "$SETUP" | awk '{ print $2 }' | sort -u)
	for verb in $got; do assert_line "$want" "$verb"; done
	for verb in $want; do assert_line "$got" "$verb"; done
	assert_eq "$(classes_of "$SKILL")" "$(grep -oE '^  [a-z-]+ \([0-9]+\):' <<<"$HELP" | awk '{ print $1 }' | sort -u)"
	# Each class row carries the exit hint --help prints.
	while read -r cls code; do
		grep -qE "^\| \`$cls\` \| $code \|" "$SKILL" || { echo "skill row for $cls lacks exit $code" >&2; return 1; }
	done < <(grep -oE '^  [a-z-]+ \([0-9]+\):' <<<"$HELP" | tr -d '():' | sort -u)
	for verb in $(grep -ohE 'LENDK_[A-Z_]+' "$SKILL" "$SETUP" | sort -u); do
		grep -qE "^  $verb " <<<"$HELP" || { echo "skill names unknown variable: $verb" >&2; return 1; }
	done
}

@test "FR38: the skill's installer classes and options are the ones install.sh uses" {
	local opts
	assert_eq "$(classes_of "$SETUP")" "$(grep -oE 'finish [a-z-]+' "$ROOT/install.sh" | awk '$2 != "ok" { print $2 }' | sort -u)"
	opts=$(grep -oE '^  --[a-z-]+' <(sh "$ROOT/install.sh" --help) | sed 's/^  //' | sort)
	assert_eq "$(sed -n 's/^Options: //p' "$SETUP" | grep -oE -e '--[a-z-]+' | sort)" "$opts"
}

@test "FR38: the skill exempts exactly the README's approved installation test, and sync is safe" {
	local cmd cmds
	cmds=$(sed -n '/^- One exemption:/,/^$/p' "$SKILL" | grep -E '^  (printf|lendk|pass) ')
	assert_eq "$(wc -l <<<"$cmds")" 3
	while IFS= read -r cmd; do
		grep -qF -e "${cmd#  }" "$ROOT/README.md" || { echo "README prompt lacks: $cmd" >&2; return 1; }
	done <<<"$cmds"
	grep -q '^`lendk check`.*`lendk sync` is safe too' "$SKILL"
	refute_contains "$(<"$SKILL")" 'Never edit the map, the shims '
}
