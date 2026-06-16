#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8791}"
BASE="http://127.0.0.1:$PORT/phpush.php"
TOKEN="$(openssl rand -hex 32 2>/dev/null || printf '%064d' 1)"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

ROOT="$(mktemp -d)"
PROJ="$(mktemp -d)"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$ROOT" "$PROJ"; }
trap cleanup EXIT

sed "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" "$RECEIVER" > "$ROOT/phpush.php"
ORIG_RECEIVER_SHA="$(shasum -a1 "$ROOT/phpush.php" | awk '{print $1}')"

php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-test-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "$BASE" && break
    sleep 0.3
done

b64u() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
hdr_tok=(-H "X-Deploy-Token: $TOKEN")

echo "== receiver security guards =="
chk "no token -> 401"                 "$(code "$BASE?action=manifest")" 401
chk "wrong token -> 401"              "$(code -H 'X-Deploy-Token: nope' "$BASE?action=manifest")" 401
chk "?token= GET fallback removed"    "$(code "$BASE?action=manifest&token=$TOKEN")" 401
chk "valid token manifest -> 200"     "$(code "${hdr_tok[@]}" "$BASE?action=manifest")" 200
chk "GET on push -> 405"              "$(code "${hdr_tok[@]}" "$BASE?action=push")" 405
chk "unknown action -> 400"           "$(code "${hdr_tok[@]}" "$BASE?action=bogus")" 400

PUSH() { code "${hdr_tok[@]}" -X POST -H "X-Deploy-Path: $(b64u "$1")" -H "X-Deploy-Final: 1" --data-binary "$2" "$BASE?action=push"; }
chk "traversal ../x -> 400"           "$(PUSH '../escape.txt' 'x')" 400
chk "did not escape via traversal"    "$([ -e "$ROOT/../escape.txt" ] && echo escaped || echo confined)" confined
PUSH '/etc/sneaky.txt' 'x' >/dev/null
chk "absolute path did NOT escape root" "$([ -e /etc/sneaky.txt ] && echo escaped || echo confined)" confined
chk "absolute path re-rooted inside"  "$([ -f "$ROOT/etc/sneaky.txt" ] && echo yes)" yes
rm -rf "${ROOT:?}/etc"
chk "case-insensitive PHPUSH.PHP -> 400" "$(PUSH 'PHPUSH.PHP' '<?php /*x*/')" 400
chk "cache file push -> 400"          "$(PUSH '.phpush-cache.php' 'x')" 400
chk "tmp-suffix push -> 400"          "$(PUSH 'x.phpush-tmp' 'x')" 400
chk "receiver untouched after attacks" "$(shasum -a1 "$ROOT/phpush.php" | awk '{print $1}')" "$ORIG_RECEIVER_SHA"

DEL() { curl -s "${hdr_tok[@]}" -X POST -H 'Content-Type: application/json' --data-binary "$1" "$BASE?action=delete"; }
DEL '["PHPUSH.PHP"]' >/dev/null
chk "delete PHPUSH.PHP blocked (receiver survives)" "$([ -f "$ROOT/phpush.php" ] && echo yes)" yes

ln -s "$PROJ" "$ROOT/symdir"
printf 'before' > "$PROJ/outside.txt"
PUSH 'symdir/outside.txt' 'AFTER-THROUGH-SYMLINK' >/dev/null
chk "symlink-dir write blocked"        "$(cat "$PROJ/outside.txt")" 'before'
rm -f "$ROOT/symdir"

echo "== client end-to-end (mirror) =="
cd "$PROJ" || exit 1
git init -q .
printf '.deploy_secret\n' > .gitignore
printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret
mkdir -p assets css
printf 'hello world\n' > index.html
printf 'body{}\n' > css/site.css
: > empty.txt
head -c 5000 /dev/zero | tr '\0' 'A' > assets/big.bin

DEPLOY_CHUNK_BYTES=1024 "$CLIENT" >/tmp/phpush-test-c1.log 2>&1
chk "first deploy exit 0" "$?" 0
verify_mirror() {
    local r want got bad=0
    while IFS= read -r -d '' r; do
        case "$r" in .deploy_secret|./.git/*|.git/*|.gitignore) continue;; esac
        [ -f "$r" ] || continue
        want="$(shasum -a1 "$r" | awk '{print $1}')"
        got="$(shasum -a1 "$ROOT/$r" 2>/dev/null | awk '{print $1}')"
        [ "$want" = "$got" ] || { echo "    mismatch: $r" >&2; bad=1; }
    done < <(git ls-files --cached --others --exclude-standard -z)
    return $bad
}
verify_mirror && ok "every file byte-for-byte on server" || bad "mirror integrity"
chk "big.bin chunk-reassembled" "$(shasum -a1 assets/big.bin | awk '{print $1}')" "$(shasum -a1 "$ROOT/assets/big.bin" | awk '{print $1}')"
chk "empty.txt present on server" "$([ -f "$ROOT/empty.txt" ] && echo yes)" yes
chk ".deploy_secret NOT uploaded" "$([ -f "$ROOT/.deploy_secret" ] && echo leaked || echo safe)" safe
chk "manifest cache file created" "$([ -f "$ROOT/.phpush-cache.php" ] && echo yes)" yes
chk "cache not mirrored back / not deletable" "$(curl -s "${hdr_tok[@]}" "$BASE?action=manifest" | grep -c '.phpush-cache.php')" 0

DEPLOY_CHUNK_BYTES=1024 "$CLIENT" 2>/dev/null | grep -q "Already in sync" && ok "idempotent re-run" || bad "idempotent re-run"

printf 'changed\n' > index.html
out="$(DEPLOY_CHUNK_BYTES=1024 "$CLIENT" 2>/dev/null)"
echo "$out" | grep -q "Upload : 1" && ok "only changed file re-uploaded" || bad "incremental upload (got: $(echo "$out" | grep Upload))"
chk "changed file updated on server" "$(shasum -a1 index.html | awk '{print $1}')" "$(shasum -a1 "$ROOT/index.html" | awk '{print $1}')"

rm css/site.css
DEPLOY_CHUNK_BYTES=1024 "$CLIENT" >/dev/null 2>&1
chk "deleted-locally removed on server" "$([ -f "$ROOT/css/site.css" ] && echo present || echo gone)" gone
chk "empty dir pruned on server" "$([ -d "$ROOT/css" ] && echo present || echo gone)" gone

printf 'keep-me\n' > index.html
rm empty.txt
DEPLOY_CHUNK_BYTES=1024 "$CLIENT" --no-delete >/dev/null 2>&1
chk "--no-delete keeps server file" "$([ -f "$ROOT/empty.txt" ] && echo kept || echo removed)" kept

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
