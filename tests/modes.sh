#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8796}"
BASE="http://127.0.0.1:$PORT/phpush.php"
TOKEN="$(openssl rand -hex 32 2>/dev/null || printf '%064d' 1)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

ROOT="$(mktemp -d)"; PROJ="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$ROOT" "$PROJ"; }
trap cleanup EXIT

sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/phpush.php"
php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-modes-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$BASE" && break; sleep 0.3; done

cd "$PROJ" || exit 1
git init -q .
git config user.email t@example.com
git config user.name tester
printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret

run() { "$CLIENT" "$@" 2>&1 | tr '\r' '\n' | grep -vE '^  uploading' || true; }
sv()  { cat "$ROOT/$1" 2>/dev/null || true; }
has() { [ -e "$ROOT/$1" ] && echo PRESENT || echo ABSENT; }
cur() { curl -s -H "X-Deploy-Token: $TOKEN" "$BASE?action=commit" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p'; }

echo "== default deploys uncommitted edits; --git ignores them =="
printf 'A1\n' > a.txt; git add a.txt; git commit -qm c1; H1="$(git rev-parse HEAD)"
printf 'A2\n' > a.txt
run >/dev/null
chk "default pushes the uncommitted edit (a=A2)" "$(sv a.txt)" "A2"
run --git >/dev/null
chk "--git resets server to committed (a=A1)" "$(sv a.txt)" "A1"
chk "--git stored the commit marker" "$(cur)" "$H1"

echo "== default never moves the commit marker =="
printf 'A3\n' > a.txt; run >/dev/null
chk "default pushed a=A3" "$(sv a.txt)" "A3"
chk "marker unchanged by default mode" "$(cur)" "$H1"

echo "== the mixing gotcha: --git only fixes committed-changed files =="
printf 'A1\n' > a.txt; printf 'B1\n' > b.txt; git add a.txt b.txt; git commit -qm c2
run --git --rehash >/dev/null
chk "clean baseline a=A1" "$(sv a.txt)" "A1"
chk "clean baseline b=B1" "$(sv b.txt)" "B1"
printf 'A9\n' > a.txt; printf 'B9\n' > b.txt
run >/dev/null
git add a.txt; git commit -qm c3
run --git >/dev/null
chk "committed file a reset to A9" "$(sv a.txt)" "A9"
chk "GOTCHA: uncommitted b stays B9 on server" "$(sv b.txt)" "B9"
run --git --rehash >/dev/null
chk "--git --rehash cleans the drift (b back to committed B1)" "$(sv b.txt)" "B1"

echo "== incremental --git leaves non-git files; full resync removes them =="
printf 'x\n' > extra.txt
run >/dev/null
chk "default deployed untracked extra.txt" "$(has extra.txt)" "PRESENT"
printf 'A10\n' > a.txt; git add a.txt; git commit -qm c4
run --git >/dev/null
chk "incremental --git keeps non-git extra.txt" "$(has extra.txt)" "PRESENT"
run --git --rehash >/dev/null
chk "full resync mirrors HEAD and removes extra.txt" "$(has extra.txt)" "ABSENT"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
