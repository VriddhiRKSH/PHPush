#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8795}"
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
php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-git-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$BASE" && break; sleep 0.3; done

hdr_tok=(-H "X-Deploy-Token: $TOKEN")
server_cursor() { curl -s "${hdr_tok[@]}" "$BASE?action=commit" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p'; }
deploy() { ( cd "$PROJ" && "$CLIENT" --git "$@" ); }
srv_sha() { shasum -a1 "$ROOT/$1" 2>/dev/null | awk '{print $1}'; }
head_sha_of() { ( cd "$PROJ" && git show "HEAD:$1" | shasum -a1 | awk '{print $1}' ); }

cd "$PROJ" || exit 1
git init -q .
git config user.email t@example.com
git config user.name tester
printf '.deploy_secret\n' > .gitignore
printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret
mkdir -p css
printf '<h1>v1</h1>\n' > index.html
printf 'body{color:red}\n' > css/site.css
printf 'keep\n' > keep.txt
git add index.html css/site.css keep.txt
git commit -q -m "initial"
HEAD1="$(git rev-parse HEAD)"

echo "== first --git deploy (no cursor -> full resync) =="
out="$(deploy 2>&1)"; rc=$?
chk "exit 0" "$rc" 0
echo "$out" | grep -q "full resync" && ok "ran as full resync" || bad "expected full resync"
chk "index.html mirrored" "$(srv_sha index.html)" "$(head_sha_of index.html)"
chk "css/site.css mirrored" "$(srv_sha css/site.css)" "$(head_sha_of css/site.css)"
chk "server cursor == HEAD1" "$(server_cursor)" "$HEAD1"
chk "cursor file not in manifest" "$(curl -s "${hdr_tok[@]}" "$BASE?action=manifest" | grep -c '.phpush-commit')" 0

echo "== uncommitted change is IGNORED =="
printf '<h1>UNCOMMITTED</h1>\n' > index.html
out="$(deploy 2>&1)"
echo "$out" | grep -q "Already in sync" && ok "uncommitted -> in sync (nothing sent)" || bad "uncommitted should be ignored"
chk "server still has committed v1" "$(srv_sha index.html)" "$(printf '<h1>v1</h1>\n' | shasum -a1 | awk '{print $1}')"
git checkout -q -- index.html

echo "== incremental: commit one change =="
printf '<h1>v2</h1>\n' > index.html
git commit -q -am "edit index"
HEAD2="$(git rev-parse HEAD)"
out="$(deploy 2>&1)"
echo "$out" | grep -q "incremental" && ok "ran as incremental" || bad "expected incremental"
echo "$out" | grep -q "Upload : 1" && ok "only the 1 changed file" || bad "expected Upload : 1 (got: $(echo "$out" | grep Upload))"
chk "index.html updated to v2" "$(srv_sha index.html)" "$(head_sha_of index.html)"
chk "cursor advanced to HEAD2" "$(server_cursor)" "$HEAD2"

echo "== incremental: add + delete + rename across one commit =="
printf 'new file\n' > added.txt
git rm -q keep.txt
git mv css/site.css css/main.css
git add added.txt
git commit -q -m "add/del/rename"
HEAD3="$(git rev-parse HEAD)"
deploy >/dev/null 2>&1
chk "added.txt present" "$(srv_sha added.txt)" "$(head_sha_of added.txt)"
chk "deleted keep.txt gone" "$([ -f "$ROOT/keep.txt" ] && echo present || echo gone)" gone
chk "renamed old path gone" "$([ -f "$ROOT/css/site.css" ] && echo present || echo gone)" gone
chk "renamed new path present" "$(srv_sha css/main.css)" "$(head_sha_of css/main.css)"
chk "cursor advanced to HEAD3" "$(server_cursor)" "$HEAD3"

echo "== --rehash forces a full resync and still matches =="
out="$(deploy --rehash 2>&1)"
echo "$out" | grep -q "full resync" && ok "--rehash -> full resync" || bad "expected full resync with --rehash"
chk "index still correct after resync" "$(srv_sha index.html)" "$(head_sha_of index.html)"

echo "== history rewrite -> auto full resync =="
curl -s "${hdr_tok[@]}" -X POST --data-binary "$(printf '%040d' 7)" "$BASE?action=commit" >/dev/null
out="$(deploy 2>&1)"
echo "$out" | grep -q "full resync" && ok "unknown server commit -> full resync" || bad "expected full resync on unknown cursor"
chk "cursor restored to HEAD3" "$(server_cursor)" "$HEAD3"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
