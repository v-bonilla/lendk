#!/bin/sh
# PROTOTYPE for #33, throwaway. Stands in for two bats tests of a 2.0 suite run under one fresh
# session keyring, each test with its own keyring named by LENDK_TEST_CACHE=name:..., as the hook
# would give it. KP names the keyprobe binary.
kp=${KP:-keyprobe}
echo "-- run start"
$kp ctx
$kp guard
export LENDK_TEST_CACHE=name:lendk-test-1
echo "-- test 1: unlock, then a second call"
$kp put lendk:suite 60 staged t1
$kp get lendk:suite plain
export LENDK_TEST_CACHE=name:lendk-test-2
echo "-- test 2: starts cold, unlocks, locks"
$kp get lendk:suite plain
$kp put lendk:suite 60 staged t2
$kp get lendk:suite plain
$kp lock lendk: plain
$kp get lendk:suite plain
echo "-- test 1's keyring after test 2's lock"
LENDK_TEST_CACHE=name:lendk-test-1 $kp get lendk:suite plain
echo "-- run end"
$kp ctx
