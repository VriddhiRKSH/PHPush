#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8797}"
BASE="http://127.0.0.1:$PORT/phpush.php"
TOKEN="$(openssl rand -hex 32 2>/dev/null || printf '%064d' 1)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

ROOT="$(mktemp -d)"; PROJS="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$ROOT" "$PROJS"; }
trap cleanup EXIT

sed -e "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" -e 's/const MAX_PUSH_BYTES = 0;/const MAX_PUSH_BYTES = 100;/' "$RECEIVER" > "$ROOT/phpush.php"
php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-sec-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$BASE" && break; sleep 0.3; done

hdr=(-H "X-Deploy-Token: $TOKEN")
b64u() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
PUSH() { code "${hdr[@]}" -X POST -H "X-Deploy-Path: $(b64u "$1")" -H "X-Deploy-Mode: ${3:-w}" -H "X-Deploy-Final: ${4:-1}" --data-binary "$2" "$BASE?action=push"; }
newproj() {
    local d; d="$(mktemp -d "$PROJS/p.XXXXXX")"
    ( cd "$d" || exit 1; git init -q .; git config user.email t@t; git config user.name t
      printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret )
    printf '%s' "$d"
}

echo "== #3: state files are NOT web-readable without the token =="
PUSH 'index.html' '<h1>hi</h1>' >/dev/null
curl -s "${hdr[@]}" "$BASE?action=manifest" >/dev/null
curl -s "${hdr[@]}" -X POST --data-binary "$(printf '%040d' 7)" "$BASE?action=commit" >/dev/null
chk "cache file created on disk" "$([ -f "$ROOT/.phpush-cache.php" ] && echo yes)" yes
chk ".phpush-cache.php over HTTP -> 404" "$(code "http://127.0.0.1:$PORT/.phpush-cache.php")" 404
chk ".phpush-cache.php body is empty" "$(curl -s "http://127.0.0.1:$PORT/.phpush-cache.php" | wc -c | tr -d ' ')" 0
chk ".phpush-commit.php over HTTP -> 404" "$(code "http://127.0.0.1:$PORT/.phpush-commit.php")" 404
chk "receiver still reads its own commit" "$(curl -s "${hdr[@]}" "$BASE?action=commit" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p')" "$(printf '%040d' 7)"

echo "== #14: responses carry X-Content-Type-Options: nosniff =="
chk "nosniff header present" "$(curl -s -D - -o /dev/null "${hdr[@]}" "$BASE?action=manifest" | grep -ci 'X-Content-Type-Options: nosniff')" 1

echo "== #6 / #7: server rejects control-character and colon (ADS) paths =="
nlp=$(printf 'ev\nil.txt' | base64 | tr '+/' '-_' | tr -d '=\n')
chk "newline path -> 400" "$(code "${hdr[@]}" -X POST -H "X-Deploy-Path: $nlp" -H "X-Deploy-Final: 1" --data-binary x "$BASE?action=push")" 400
chk "colon/ADS path -> 400" "$(PUSH 'phpush.php::$DATA' 'x')" 400

echo "== #12: commit file is protected from push/delete =="
chk "push .phpush-commit.php -> 400" "$(PUSH '.phpush-commit.php' 'x')" 400
curl -s "${hdr[@]}" -X POST -H 'Content-Type: application/json' --data-binary '[".phpush-commit.php"]' "$BASE?action=delete" >/dev/null
chk "delete blocked, commit file survives" "$([ -f "$ROOT/.phpush-commit.php" ] && echo yes)" yes

echo "== #5: MAX_PUSH_BYTES is cumulative across append chunks (cap=100) =="
chk "chunk1 50B (w) -> 200" "$(PUSH 'big.bin' "$(head -c 50 /dev/zero | tr '\0' A)" w 0)" 200
chk "chunk2 60B (a) exceeds cap -> 413" "$(PUSH 'big.bin' "$(head -c 60 /dev/zero | tr '\0' B)" a 1)" 413

echo "== #8a: client skips symlinks (no exfiltration) =="
SECRET="$(mktemp)"; echo 'PRIVATE-KEY' > "$SECRET"
D="$(newproj)"; ( cd "$D" || exit 1; printf 'real\n' > real.txt; ln -s "$SECRET" leak.txt; "$CLIENT" >/dev/null 2>&1 )
chk "real file deployed" "$([ -f "$ROOT/real.txt" ] && echo yes)" yes
chk "symlink target NOT exfiltrated" "$([ -f "$ROOT/leak.txt" ] && echo LEAKED || echo safe)" safe
rm -f "$SECRET"

echo "== #15: nested .deploy_secret is skipped at any depth =="
D="$(newproj)"; ( cd "$D" || exit 1; mkdir -p sub; printf 'TOKEN=x\n' > sub/.deploy_secret; printf 'page\n' > sub/index.html; "$CLIENT" >/dev/null 2>&1 )
chk "nested sub/index.html deployed" "$([ -f "$ROOT/sub/index.html" ] && echo yes)" yes
chk "nested sub/.deploy_secret NOT deployed" "$([ -f "$ROOT/sub/.deploy_secret" ] && echo LEAKED || echo safe)" safe

echo "== #8b: refuse a git-committed .deploy_secret =="
D="$(newproj)"; out="$( cd "$D" || exit 1; git add .deploy_secret; git commit -qm s; "$CLIENT" 2>&1 )"
echo "$out" | grep -qi 'committed to this git repository' && ok "refused committed .deploy_secret" || bad "did not refuse committed secret"

echo "== #8c: refuse a DEPLOY_TOKEN containing a newline =="
D="$(newproj)"; nl_token=$'aaaaaaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbbbbbb'
out="$( cd "$D" || exit 1; DEPLOY_URL="$BASE" DEPLOY_TOKEN="$nl_token" "$CLIENT" 2>&1 )"
echo "$out" | grep -qi 'newline' && ok "refused newline token" || bad "did not refuse newline token"

echo "== #9: --git refuses an empty-tree commit (no silent wipe) =="
D="$(newproj)"
( cd "$D" || exit 1; printf 'NINE\n' > nine.txt; git add nine.txt; git commit -qm c1; "$CLIENT" >/dev/null 2>&1 )
out="$( cd "$D" || exit 1; git rm -q nine.txt; git commit -qm emptied; "$CLIENT" --git 2>&1 )"
echo "$out" | grep -qi 'refusing to wipe\|no deployable files' && ok "--git refused empty-tree commit" || bad "--git did not refuse empty tree"
chk "server NOT wiped (nine.txt survives)" "$([ -f "$ROOT/nine.txt" ] && echo yes)" yes

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
