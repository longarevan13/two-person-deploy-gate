#!/usr/bin/env bash
# Exercises bin/deploy against a mock GitHub API and a static web server. No network, no Docker needed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); DEPLOY="$HERE/../bin/deploy"
T=$(mktemp -d); export HEALTH_TRIES=3 GATE_ROOT=$T GATE_GITHUB_API=http://127.0.0.1:18080 FRONTEND_HEALTH_URL=http://127.0.0.1:18201/current/release.json
mkdir -p "$T/etc" "$T/web/releases"; echo test-token > "$T/.deploy-token"; chmod 600 "$T/.deploy-token"
printf 'alice\nbob\n' > "$T/etc/approvers"
S="$T/scenario.json"
scen() { python3 - "$S" "$@" <<'PY'
import json,sys
p=sys.argv[1]; kv=dict(a.split("=",1) for a in sys.argv[2:])
d={"tag":kv["tag"],"sha":"abc1234abc1234","author":"alice",
   "reviews":json.loads(kv.get("reviews",'[{"state":"APPROVED","commit_id":"head1","user":{"login":"bob"}}]'))}
for k in ("compare","merge_sha"):
    if k in kv: d[k]=kv[k]
for k in ("bad_sum","broken_build"):
    if k in kv: d[k]=True
json.dump(d,open(p,"w"))
PY
}
scen tag=release-20260922-aaaaaaa
python3 "$HERE/mock_github.py" 18080 "$S" & M=$!
python3 -m http.server 18201 --bind 127.0.0.1 --directory "$T/web" >/dev/null 2>&1 & W=$!
sleep 1
pass=0; fail=0
expect() { # expect <ok|refused:reason-substring> <label> <args...>
  local want=${1%%:*} why=${1#*:} label=$2
  [ "$why" = "$1" ] && why=""
  shift 2
  if SSH_ORIGINAL_COMMAND="$*" bash "$DEPLOY" >/dev/null 2>"$T/err"; then got=ok; else got=refused; fi
  if [ "$got" = "$want" ] && { [ -z "$why" ] || grep -q -- "$why" "$T/err"; }; then pass=$((pass+1)); echo "PASS $label"; else fail=$((fail+1)); echo "FAIL $label (got $got)"; tail -3 "$T/err"; fi
}
check() { # check <label> <test command...>
  local label=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS $label"; else fail=$((fail+1)); echo "FAIL $label"; fi
}
cur() { readlink "$T/web/current"; }

expect ok      "deploy A approved by the other person"      frontend release-20260922-aaaaaaa
check "current is A" [ "$(cur)" = releases/release-20260922-aaaaaaa ]
scen tag=release-20260922-bbbbbbb
expect ok      "deploy B approved by the other person"      frontend release-20260922-bbbbbbb
scen tag=release-20260922-ccccccc reviews='[{"state":"APPROVED","commit_id":"head1","user":{"login":"alice"}}]'
expect "refused:no approval from a second person" "self-approval only"                frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc reviews='[{"state":"APPROVED","commit_id":"oldhead","user":{"login":"bob"}}]'
expect "refused:no approval from a second person" "approval on an older commit"       frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc reviews='[{"state":"APPROVED","commit_id":"head1","user":{"login":"bob"}},{"state":"CHANGES_REQUESTED","commit_id":"head1","user":{"login":"bob"}}]'
expect "refused:no approval from a second person" "approval later withdrawn"          frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc reviews='[{"state":"APPROVED","commit_id":"head1","user":{"login":"mallory"}}]'
expect "refused:no approval from a second person" "approver not on the approvers list" frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc compare=diverged
expect "refused:is not on main" "commit not on main"                                frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc merge_sha=somethingelse
expect "refused:not the merge commit" "direct push, not a PR merge commit"          frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc bad_sum=1
expect "refused:sha256 mismatch" "checksum mismatch"                                frontend release-20260922-ccccccc
scen tag=release-20260922-ccccccc broken_build=1
expect "refused:failed its health check; rolled back" "health check fails, auto rollback" frontend release-20260922-ccccccc
check "still on B after failed deploy" [ "$(cur)" = releases/release-20260922-bbbbbbb ]
expect "refused:bad tag format" "bad tag format"                                    frontend 'release-x;id'
expect "refused:usage:" "unknown command"                                           'bash -i'
expect "refused:usage:" "extra arguments"                                           frontend release-20260922-aaaaaaa extra
expect "refused:backend is not installed" "backend not installed yet"               backend release-20260922-aaaaaaa
expect ok      "rollback frontend"                          rollback frontend
check "rolled back to A" [ "$(cur)" = releases/release-20260922-aaaaaaa ]
for x in d e f 1 2 3; do scen tag=release-20260923-$x$x$x$x$x$x$x; expect ok "deploy $x for pruning" frontend release-20260923-$x$x$x$x$x$x$x; done
check "pruned to at most 5 releases" [ "$(ls "$T/web/releases" | wc -l)" -le 5 ]
expect ok      "status"                                     status
check "token never written to the log" bash -c "! grep -q test-token '$T/log/deploy.log'"
kill $M $W 2>/dev/null; echo "passed=$pass failed=$fail"; rm -rf "$T"
[ "$fail" -eq 0 ]
