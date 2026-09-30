#!/usr/bin/env bats
# FR26: the SHIMS.lock that sync holds.

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LEND_SHIMS=$SB/shims K1=one
	LOCK=$LEND_SHIMS.lock
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf 'stub K1\n' >"$HOME/.config/lend/map"
	chmod 600 "$HOME/.config/lend/map"
}

teardown() {
	[[ -z ${OWNER-} ]] || kill "$OWNER" 2>/dev/null || true
}

# dead_pid: the PID of a process that has exited.
dead_pid() {
	local p
	sh -c 'exit 0' &
	p=$!
	wait "$p"
	printf '%s\n' "$p"
}

@test "FR26: sync breaks a dead owner's lock and leaves no lock behind" {
	mkdir "$LOCK"
	dead_pid >"$LOCK/pid"
	run_lend sync
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	[[ -f $LEND_SHIMS/stub ]]
	[[ ! -e $LOCK && ! -e $LOCK.break ]]
}

@test "FR26: sync breaks a lock that never got an owner after 1 s" {
	mkdir "$LOCK"
	run_lend sync
	assert_eq "$status" 0
	[[ -f $LEND_SHIMS/stub && ! -e $LOCK ]]
}

@test "FR26: a live owner's lock gives write naming the lock after 10 s" {
	sleep 60 &
	OWNER=$!
	mkdir "$LOCK"
	printf '%s\n' "$OWNER" >"$LOCK/pid"
	local start=$SECONDS
	run_lend sync
	assert_eq "$stderr" "lend: write: $LOCK: held by PID $OWNER for 10 s. Stop and ask the user."
	assert_class write 125
	((SECONDS - start >= 10 && SECONDS - start <= 13))
	assert_eq "$(cat "$LOCK/pid")" "$OWNER"
	[[ ! -e $LEND_SHIMS/stub ]]
}

@test "FR26: concurrent syncs started with a dead owner's lock all finish, one at a time" {
	local i st=0
	mkdir "$LOCK"
	dead_pid >"$LOCK/pid"
	for i in 1 2 3 4 5 6 7 8 9 10; do
		"$LEND" sync </dev/null 2>"$SB/err.$i" &
	done
	for i in 1 2 3 4 5 6 7 8 9 10; do wait -n || st=$?; done
	assert_eq "$st" 0
	assert_eq "$(cat "$SB"/err.*)" ""
	[[ -f $LEND_SHIMS/stub && ! -e $LOCK && ! -e $LOCK.break ]]
}

@test "FR26: a waiter killed while holding the break marker leaves a lock the next sync breaks" {
	local pid i
	mkdir "$LOCK"
	dead_pid >"$LOCK/pid"
	LEND_TEST_PAUSE=9 "$LEND" sync </dev/null 2>/dev/null &
	pid=$!
	for ((i = 0; i < 50; i++)); do
		[[ $(cat "$LOCK.break/pid" 2>/dev/null) == "$pid" ]] && break
		sleep 0.1
	done
	assert_eq "$(cat "$LOCK.break/pid")" "$pid"
	kill -KILL "$pid"
	wait "$pid" || true
	local start=$SECONDS
	run_lend sync
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	((SECONDS - start <= 3))
	[[ -f $LEND_SHIMS/stub ]]
	assert_eq "$(compgen -G "$LOCK*")" ""
}

@test "FR26: a break marker that never got a PID is taken over after 1 s" {
	mkdir "$LOCK" "$LOCK.break"
	dead_pid >"$LOCK/pid"
	run_lend sync
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	[[ -f $LEND_SHIMS/stub ]]
	assert_eq "$(compgen -G "$LOCK*")" ""
}

@test "FR26: a live waiter's break marker is left alone, so the lock stays until it is done" {
	sleep 60 &
	OWNER=$!
	mkdir "$LOCK" "$LOCK.break"
	dead_pid >"$LOCK/pid"
	printf '%s\n' "$OWNER" >"$LOCK.break/pid"
	run_lend sync
	assert_class write 125
	assert_eq "$(cat "$LOCK.break/pid")" "$OWNER"
	[[ -f $LOCK/pid && ! -e $LOCK.break/break ]]
}

@test "FR26: runtime calls never lock" {
	sleep 60 &
	OWNER=$!
	mkdir -p "$LOCK" && printf '%s\n' "$OWNER" >"$LOCK/pid"
	run_lend run -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
}
