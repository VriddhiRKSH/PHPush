#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8803}"
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
php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-hashcache-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$BASE" && break; sleep 0.3; done

sha() { shasum -a1 "$1" 2>/dev/null | awk '{print $1}' || sha1sum "$1" | awk '{print $1}'; }
run() { "$CLIENT" "$@" 2>&1 | tr '\r' '\n' | grep -vE '^  uploading'; }

cd "$PROJ" || exit 1
git init -q .; git config user.email t@t; git config user.name t
printf '.deploy_secret*\n' > .gitignore
printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret
printf 'A1\n' > a.txt
printf 'sp\n' > "sp ace.txt"
printf 'un\n' > "ünïcode.txt"
printf 'bs\n' > 'back\slash.txt'
touch -t 202001010000 "sp ace.txt"

echo "== batched hashing deploys awkward names byte-for-byte =="
out="$(run)"
for f in a.txt "sp ace.txt" "ünïcode.txt"; do
    chk "mirrored: $f" "$(sha "$ROOT/$f")" "$(sha "$f")"
done
echo "$out" | grep -q "skipping 'back" && ok "backslash name skipped with a warning" || bad "no skip warning for the backslash name"
chk "backslash name NOT smuggled into a subdir" "$([ -e "$ROOT/back/slash.txt" ] && echo smuggled || echo safe)" safe
rm 'back\slash.txt'

echo "== the local fingerprint cache exists and lives inside .git =="
chk "cache file created" "$([ -f .git/phpush-hash-cache ] && echo yes)" yes
head -1 .git/phpush-hash-cache | grep -q '^#phpush-cache-v1 ' && ok "cache has a versioned header" || bad "cache header wrong"
git ls-files --cached --others --exclude-standard | grep -q phpush-hash-cache && bad "cache leaks into the deploy list" || ok "cache never enters the deploy list"

echo "== warm re-runs stay in sync (cache serving hashes) =="
run | grep -q "Already in sync" && ok "second run in sync" || bad "second run not in sync"
run | grep -q "Already in sync" && ok "third run in sync (warm cache)" || bad "third run not in sync"

echo "== a content change is detected and shipped =="
printf 'A2-changed\n' > a.txt
out="$(run)"
echo "$out" | grep -q "Upload : 1" && ok "exactly the changed file re-uploads" || bad "wrong upload count: $(echo "$out" | grep Upload)"
chk "server has the new content" "$(cat "$ROOT/a.txt")" "A2-changed"

echo "== an mtime-only touch re-hashes but uploads nothing =="
touch a.txt
run | grep -q "Already in sync" && ok "touch alone stays in sync" || bad "touch caused an upload"

echo "== --rehash catches a same-size same-mtime rewrite (the documented blind spot) =="
printf 'XY\n' > "sp ace.txt"
touch -t 202001010000 "sp ace.txt"
run | grep -q "Already in sync" && ok "stale caches miss it (as documented)" || bad "expected the caches to miss it"
out="$(run --rehash)"
echo "$out" | grep -q "Upload : 1" && ok "--rehash re-detects it" || bad "--rehash missed it: $(echo "$out" | grep Upload)"
chk "server updated after --rehash" "$(cat "$ROOT/sp ace.txt")" "XY"
run | grep -q "Already in sync" && ok "back in sync afterwards" || bad "not in sync after --rehash"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
