#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8801}"
BASE="http://127.0.0.1:$PORT/main/phpush.php"
TOKEN="$(openssl rand -hex 32 2>/dev/null || printf '%064d' 1)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has() { if echo "$2" | grep -qi "$3"; then ok "$1"; else bad "$1 (no '$3' in output)"; fi; }

ROOT="$(mktemp -d)"; PROJ="$(mktemp -d)"; PROJ2="$(mktemp -d)"; PROJ3="$(mktemp -d)"; PROJ4="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$ROOT" "$PROJ" "$PROJ2" "$PROJ3" "$PROJ4"; }
trap cleanup EXIT

mkdir -p "$ROOT/main"
sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/main/phpush.php"
sed -e "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" -e 's/const MAX_BACKUPS = 10;/const MAX_BACKUPS = 0;/' "$RECEIVER" > "$ROOT/nobackups.php"
cp "$RECEIVER" "$ROOT/exposed.txt"
printf 'just a text file\n' > "$ROOT/plain.txt"
mkdir -p "$ROOT/fresh"
sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/fresh/phpush.php"
printf 'legacy\n' > "$ROOT/fresh/legacy.html"

php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-doctor-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$BASE" && break; sleep 0.3; done

cd "$PROJ" || exit 1
git init -q .; git config user.email t@t; git config user.name t
printf '.deploy_secret*\n' > .gitignore
printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret
printf 'hello\n' > index.html
"$CLIENT" >/dev/null 2>&1

echo "== doctor: healthy setup (php -S serves the backup dir, so exactly that is flagged) =="
out="$("$CLIENT" doctor 2>&1)"; rc=$?
has "receiver runs as PHP + 401 check passes" "$out" "rejects requests without a token"
has "token accepted"                          "$out" "deploy token accepted"
has "versions match"                          "$out" "client and server both v"
has "secret file hygiene checked"             "$out" "is gitignored"
has "web-readable backup dir detected"        "$out" "READABLE from the web"
chk "doctor exits 1 on that one problem" "$rc" 1

echo "== doctor: all-clear when backups are off (nothing web-readable to flag) =="
out="$(DEPLOY_URL="http://127.0.0.1:$PORT/nobackups.php" DEPLOY_TOKEN="$TOKEN" "$CLIENT" doctor 2>&1)"; rc=$?
has "reports backups turned off" "$out" "backups are turned off"
has "prints the all-clear"       "$out" "All checks passed"
chk "doctor exits 0 when clean" "$rc" 0

echo "== doctor: catches phpush.php served as plain text (token exposure) =="
out="$(DEPLOY_URL="http://127.0.0.1:$PORT/exposed.txt" DEPLOY_TOKEN="$TOKEN" "$CLIENT" doctor 2>&1)"; rc=$?
has "flags source served as text" "$out" "PLAIN TEXT"
has "tells the user to rotate"    "$out" "NEW token"
chk "doctor exits 1 on exposure" "$rc" 1

echo "== doctor: catches a rejected token =="
out="$(DEPLOY_URL="$BASE" DEPLOY_TOKEN="$(printf '%064d' 7)" "$CLIENT" doctor 2>&1)"; rc=$?
has "flags the rejected token" "$out" "REJECTED the deploy token"
chk "doctor exits 1 on bad token" "$rc" 1

echo "== doctor: catches a secret file that is not gitignored =="
( cd "$PROJ2" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret )
out="$( cd "$PROJ2" && "$CLIENT" doctor 2>&1 )"; rc=$?
has "flags the unignored secret" "$out" "NOT gitignored"
chk "doctor exits 1 on unignored secret" "$rc" 1

echo "== deploy handshake: hard stop instead of a silent shrug =="
out="$( cd "$PROJ" && DEPLOY_URL="http://127.0.0.1:$PORT/exposed.txt" DEPLOY_TOKEN="$TOKEN" "$CLIENT" 2>&1 )"; rc=$?
has "deploy refuses a source-serving host" "$out" "PHP SOURCE CODE"
chk "deploy exits 1 on source exposure" "$rc" 1
out="$( cd "$PROJ" && DEPLOY_URL="http://127.0.0.1:$PORT/plain.txt" DEPLOY_TOKEN="$TOKEN" "$CLIENT" 2>&1 )"; rc=$?
has "deploy refuses a non-receiver reply" "$out" "did not answer like a PHPush receiver"
chk "deploy exits 1 on non-receiver" "$rc" 1
out="$( cd "$PROJ" && DEPLOY_URL="http://127.0.0.1:1/phpush.php" DEPLOY_TOKEN="$TOKEN" "$CLIENT" 2>&1 )"; rc=$?
has "deploy reports an unreachable server" "$out" "could not reach"
chk "deploy exits 1 when unreachable" "$rc" 1
out="$( cd "$PROJ" && DEPLOY_URL="$BASE" DEPLOY_TOKEN="$(printf '%064d' 7)" "$CLIENT" 2>&1 )"; rc=$?
has "deploy reports a rejected token clearly" "$out" "rejected the deploy token"
chk "deploy exits 1 on rejected token" "$rc" 1

echo "== --no-handshake: unverified server means deletes need --adopt =="
( cd "$PROJ3" && git init -q . && git config user.email t@t && git config user.name t \
  && printf '.deploy_secret*\n' > .gitignore \
  && printf 'DEPLOY_URL="http://127.0.0.1:%s/fresh/phpush.php"\nDEPLOY_TOKEN="%s"\n' "$PORT" "$TOKEN" > .deploy_secret \
  && printf 'mine\n' > mine.html )
out="$( cd "$PROJ3" && "$CLIENT" --no-handshake 2>&1 )"; rc=$?
chk "refused (exit 1)" "$rc" 1
has "explains the unverified-delete refusal" "$out" "no-handshake"
chk "foreign file untouched" "$([ -f "$ROOT/fresh/legacy.html" ] && echo present)" present
( cd "$PROJ3" && "$CLIENT" --no-handshake --adopt >/dev/null 2>&1 ); rc=$?
chk "--no-handshake --adopt deploys (exit 0)" "$rc" 0
chk "adopt removed the foreign file" "$([ -f "$ROOT/fresh/legacy.html" ] && echo present || echo gone)" gone
chk "adopt deployed the project" "$(cat "$ROOT/fresh/mine.html" 2>/dev/null)" "mine"

echo "== --no-delete does not adopt an unmanaged server (guard stays armed) =="
mkdir -p "$ROOT/fresh2"
sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/fresh2/phpush.php"
printf 'legacy2\n' > "$ROOT/fresh2/legacy2.html"
( cd "$PROJ4" && git init -q . && git config user.email t@t && git config user.name t \
  && printf '.deploy_secret*\n' > .gitignore \
  && printf 'DEPLOY_URL="http://127.0.0.1:%s/fresh2/phpush.php"\nDEPLOY_TOKEN="%s"\n' "$PORT" "$TOKEN" > .deploy_secret \
  && printf 'mine2\n' > mine2.html )
( cd "$PROJ4" && "$CLIENT" --no-delete >/dev/null 2>&1 ); rc=$?
chk "--no-delete escape hatch deploys (exit 0)" "$rc" 0
chk "uploaded alongside the foreign file" "$(cat "$ROOT/fresh2/mine2.html" 2>/dev/null)" "mine2"
chk "foreign file kept" "$([ -f "$ROOT/fresh2/legacy2.html" ] && echo present)" present
out="$( cd "$PROJ4" && "$CLIENT" 2>&1 )"; rc=$?
chk "a later plain run is STILL refused (guard not disarmed)" "$rc" 1
has "still requires --adopt" "$out" "adopt"
chk "foreign file still present" "$([ -f "$ROOT/fresh2/legacy2.html" ] && echo present)" present

echo "== --yes is accepted (non-interactive runs never prompt anyway) =="
out="$( cd "$PROJ" && "$CLIENT" --yes 2>&1 )"; rc=$?
chk "--yes run exits 0" "$rc" 0

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
