#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8802}"
TOKEN="$(openssl rand -hex 32 2>/dev/null || printf '%064d' 1)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has() { if echo "$2" | grep -qi "$3"; then ok "$1"; else bad "$1 (no '$3' in output)"; fi; }

ROOT="$(mktemp -d)"; PROJ="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$ROOT" "$PROJ"; }
trap cleanup EXIT

mkdir -p "$ROOT/a" "$ROOT/b"
sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/a/phpush.php"
sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/b/phpush.php"
php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-target-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$PORT/a/phpush.php" && break; sleep 0.3; done

cd "$PROJ" || exit 1
git init -q .; git config user.email t@t; git config user.name t
printf '.deploy_secret*\n!.deploy_secret.example\n' > .gitignore
printf 'DEPLOY_URL="http://127.0.0.1:%s/a/phpush.php"\nDEPLOY_TOKEN="%s"\n' "$PORT" "$TOKEN" > .deploy_secret.staging
printf 'DEPLOY_URL="http://127.0.0.1:%s/b/phpush.php"\nDEPLOY_TOKEN="%s"\n' "$PORT" "$TOKEN" > .deploy_secret.prod
printf 'T\n' > index.html

echo "== with named targets, a bare run refuses to guess =="
out="$("$CLIENT" 2>&1)"; rc=$?
chk "bare run exits 1" "$rc" 1
has "lists the available targets" "$out" "staging"
has "points at --target"          "$out" "phpush --target"

echo "== --target picks exactly the named destination =="
out="$("$CLIENT" --target staging 2>&1)"; rc=$?
chk "staging deploy exits 0" "$rc" 0
has "target name shown on the Target line" "$out" "\[staging\]"
chk "staging (a/) got the file"   "$(cat "$ROOT/a/index.html" 2>/dev/null)" "T"
chk "prod (b/) did NOT get it"    "$([ -f "$ROOT/b/index.html" ] && echo present || echo absent)" absent
"$CLIENT" --target=prod >/dev/null 2>&1; rc=$?
chk "--target=prod (equals form) exits 0" "$rc" 0
chk "prod (b/) now has the file"  "$(cat "$ROOT/b/index.html" 2>/dev/null)" "T"

echo "== the secret files themselves never deploy =="
chk "no secret in a/" "$(find "$ROOT/a" -name '*deploy_secret*' | wc -l | tr -d ' ')" 0
chk "no secret in b/" "$(find "$ROOT/b" -name '*deploy_secret*' | wc -l | tr -d ' ')" 0

echo "== unknown target names the known ones =="
out="$("$CLIENT" --target bogus 2>&1)"; rc=$?
chk "unknown target exits 1" "$rc" 1
has "lists what exists" "$out" "available: prod staging"

echo "== --target refuses to fight the environment variables =="
out="$(DEPLOY_URL="http://127.0.0.1:$PORT/a/phpush.php" DEPLOY_TOKEN="$TOKEN" "$CLIENT" --target staging 2>&1)"; rc=$?
chk "env conflict exits 1" "$rc" 1
has "explains the conflict" "$out" "unset the env vars"

echo "== a stray plain .deploy_secret earns a rename hint =="
printf 'DEPLOY_URL="http://127.0.0.1:%s/a/phpush.php"\nDEPLOY_TOKEN="%s"\n' "$PORT" "$TOKEN" > .deploy_secret
out="$("$CLIENT" 2>&1)"; rc=$?
chk "still refuses (exit 1)" "$rc" 1
has "suggests renaming the plain file" "$out" "rename it to"
rm .deploy_secret

echo "== a committed target secret is refused =="
git add -f .deploy_secret.staging >/dev/null 2>&1
git commit -qm secret >/dev/null 2>&1
out="$("$CLIENT" --target staging 2>&1)"; rc=$?
chk "committed secret exits 1" "$rc" 1
has "names the committed file" "$out" "deploy_secret.staging is committed"
git rm -q --cached .deploy_secret.staging >/dev/null 2>&1
git commit -qm unsecret >/dev/null 2>&1

echo "== doctor works per target =="
out="$("$CLIENT" doctor --target staging 2>&1)"
has "doctor checks the staging receiver" "$out" "deploy token accepted"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
