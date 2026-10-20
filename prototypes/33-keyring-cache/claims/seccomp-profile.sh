#!/bin/sh
# PROTOTYPE for #33, throwaway: print Docker's default seccomp profile with add_key and keyctl allowed.
# Usage: claims/seccomp-profile.sh >profile.json
set -eu
curl -sSfL https://raw.githubusercontent.com/moby/profiles/main/seccomp/default.json |
	python3 -c 'import json,sys; d=json.load(sys.stdin); d["syscalls"].append({"names":["add_key","keyctl"],"action":"SCMP_ACT_ALLOW"}); json.dump(d,sys.stdout,indent=1)'
