#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$HERE/phpush.php"
CLIENT="$HERE/phpush"
PORT="${PHPUSH_TEST_PORT:-8798}"
BASE="http://127.0.0.1:$PORT/phpush.php"
TOKEN="$(openssl rand -hex 32 2>/dev/null || printf '%064d' 1)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

ROOT="$(mktemp -d)"; PROJ="$(mktemp -d)"; GP="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$ROOT" "$PROJ" "$GP"; }
trap cleanup EXIT

# MAX_BACKUPS lowered to 3 so pruning is cheap to exercise.
sed -e "s/__PASTE_64_HEX_TOKEN_HERE__/$TOKEN/" -e 's/const MAX_BACKUPS = 10;/const MAX_BACKUPS = 3;/' "$RECEIVER" > "$ROOT/phpush.php"
php -S "127.0.0.1:$PORT" -t "$ROOT" >/tmp/phpush-backup-srv.log 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$BASE" && break; sleep 0.3; done

hdr=(-H "X-Deploy-Token: $TOKEN")
sv()   { cat "$ROOT/$1" 2>/dev/null || true; }
has()  { [ -e "$ROOT/$1" ] && echo PRESENT || echo ABSENT; }
run()  { ( cd "$PROJ" && "$CLIENT" "$@" 2>&1 | tr '\r' '\n' | grep -vE '^  uploading' ) || true; }
snapcount() { curl -s "${hdr[@]}" "$BASE?action=backups" | grep -o '"id":"[^"]*"' | wc -l | tr -d ' '; }

cd "$PROJ" || exit 1
git init -q .; git config user.email t@t; git config user.name t
printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret

echo "== --list-backups on a fresh server says so plainly =="
( cd "$PROJ" && "$CLIENT" --list-backups >/dev/null 2>&1 ); rc=$?
chk "exits 0 with no snapshots" "$rc" 0
out="$(run --list-backups)"
echo "$out" | grep -qi 'No rollback snapshots' && ok "prints the empty-list message" || bad "empty list broken: $out"

echo "== a deploy that overwrites/adds/deletes can be rolled back exactly =="
printf 'A\n' > index.html; printf 'K\n' > keep.txt
run >/dev/null
chk "v1 index deployed" "$(sv index.html)" "A"
sleep 1
printf 'B\n' > index.html; printf 'N\n' > new.txt; rm keep.txt
run >/dev/null
chk "v2 index overwritten" "$(sv index.html)" "B"
chk "v2 new file added"    "$(has new.txt)" "PRESENT"
chk "v2 deleted keep.txt"  "$(has keep.txt)" "ABSENT"
run --rollback >/dev/null
chk "rollback restored old index"        "$(sv index.html)" "A"
chk "rollback removed the added file"    "$(has new.txt)" "ABSENT"
chk "rollback restored the deleted file" "$(sv keep.txt)" "K"
# re-sync the working tree to the rolled-back server so the next block is clean
printf 'A\n' > index.html; printf 'K\n' > keep.txt; rm -f new.txt

echo "== --list-backups shows snapshots; --rollback --dry-run changes nothing =="
out="$(run --list-backups)"
echo "$out" | grep -qi 'snapshot' && ok "list-backups prints snapshots" || bad "list-backups printed nothing"
sleep 1
printf 'B2\n' > index.html
run >/dev/null
chk "change deployed" "$(sv index.html)" "B2"
out="$(run --rollback --dry-run)"
echo "$out" | grep -qi 'dry run' && ok "dry-run rollback says dry run" || bad "no dry-run marker"
chk "dry-run did NOT touch the server" "$(sv index.html)" "B2"
run --rollback >/dev/null
chk "real rollback reverted the change" "$(sv index.html)" "A"
printf 'A\n' > index.html

echo "== --no-backup records no new snapshot =="
before="$(snapcount)"
sleep 1
printf 'D\n' > index.html
run --no-backup >/dev/null
chk "server took the change" "$(sv index.html)" "D"
chk "no new snapshot recorded" "$(snapcount)" "$before"

echo "== snapshots are pruned to MAX_BACKUPS (=3 here) =="
for i in 1 2 3 4 5; do sleep 1; printf 'P%s\n' "$i" > index.html; run >/dev/null; done
chk "snapshot count capped at MAX_BACKUPS" "$(snapcount)" "3"

echo "== backup area is invisible and protected =="
chk "backups never appear in the manifest" "$(curl -s "${hdr[@]}" "$BASE?action=manifest" | grep -c 'phpush-backups')" 0
chk "the mirror never deletes the backup dir" "$([ -d "$ROOT/.phpush-backups" ] && echo yes)" yes
chk "backup dir carries an .htaccess deny"    "$([ -f "$ROOT/.phpush-backups/.htaccess" ] && echo yes)" yes

echo "== a reused snapshot id cannot clobber an earlier backup (no data loss) =="
b64u() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
pushs() { curl -s -o /dev/null "${hdr[@]}" -X POST -H "X-Deploy-Path: $(b64u "$1")" -H "X-Deploy-Mode: w" -H "X-Deploy-Final: 1" -H "X-Deploy-Offset: 0" -H "X-Deploy-Snapshot: $3" --data-binary "$2" "$BASE?action=push"; }
printf 'ORIG\n' > "$ROOT/collide.txt"
pushs collide.txt 'V1' fixedsnap
pushs collide.txt 'V2' fixedsnap
chk "server has the latest content" "$(sv collide.txt)" "V2"
curl -s "${hdr[@]}" -X POST "$BASE?action=rollback&snapshot=fixedsnap" >/dev/null
chk "rollback restored the TRUE original (no data loss)" "$(sv collide.txt)" "ORIG"

echo "== a deploy refuses to change files when the backup cannot be written =="
prev="$(sv index.html)"
printf 'G\n' > guard.txt
run >/dev/null
chmod 555 "$ROOT/.phpush-backups"
sleep 1
printf 'FL\n' > index.html
out="$( cd "$PROJ" && "$CLIENT" 2>&1 )"; rc=$?
chk "deploy aborted before uploading (exit 1)" "$rc" 1
echo "$out" | grep -qi 'cannot write backup snapshots' && ok "preflight names the cause" || bad "no backup-failure message: $out"
chk "server file untouched" "$(sv index.html)" "$prev"
resp="$(curl -s "${hdr[@]}" -X POST -H "X-Deploy-Path: $(b64u index.html)" -H "X-Deploy-Mode: w" -H "X-Deploy-Final: 1" -H "X-Deploy-Offset: 0" -H "X-Deploy-Snapshot: failsnap1" --data-binary 'DIRECT-OVERWRITE' "$BASE?action=push")"
echo "$resp" | grep -q 'backup failed' && ok "receiver hard-fails an overwrite it cannot back up" || bad "receiver did not refuse: $resp"
chk "server file still untouched" "$(sv index.html)" "$prev"
resp="$(curl -s "${hdr[@]}" -X POST -H 'Content-Type: application/json' -H 'X-Deploy-Snapshot: failsnap2' --data-binary '["guard.txt"]' "$BASE?action=delete")"
echo "$resp" | grep -q 'backup failed — not deleted' && ok "receiver refuses a delete it cannot back up" || bad "delete not refused: $resp"
chk "guarded file still present" "$(has guard.txt)" "PRESENT"
chmod 755 "$ROOT/.phpush-backups"
printf '%s\n' "$prev" > index.html
rm guard.txt
run >/dev/null

echo "== rollback prints an undo id, and the undo restores the newer state =="
sleep 1
printf 'U2\n' > index.html
run >/dev/null
out="$(run --rollback)"
echo "$out" | grep -q 'Undo this rollback' && ok "undo hint printed" || bad "no undo hint: $out"
chk "rollback restored the older content" "$(sv index.html)" "$prev"
undo="$(echo "$out" | sed -n 's/.*Undo this rollback:  phpush --rollback \([A-Za-z0-9._-]*\).*/\1/p' | head -1)"
run --rollback "$undo" >/dev/null
chk "undoing the rollback brings the newer content back" "$(sv index.html)" "U2"

echo "== --rollback --no-backup leaves no undo handle =="
sleep 1
printf 'U3\n' > index.html
run >/dev/null
out="$(run --rollback --no-backup)"
echo "$out" | grep -q 'Undo this rollback' && bad "unexpected undo hint with --no-backup" || ok "no undo hint with --no-backup"
chk "the rollback itself still worked" "$(sv index.html)" "U2"
printf 'U2\n' > index.html

echo "== a half-failing rollback says PARTIAL and lists the file =="
sleep 1
printf 'U4\n' > index.html
run >/dev/null
rm -f "$ROOT/index.html"; mkdir "$ROOT/index.html"
out="$( cd "$PROJ" && "$CLIENT" --rollback 2>&1 )"; rc=$?
chk "partial rollback exits 1" "$rc" 1
echo "$out" | grep -qi 'PARTIAL' && ok "says PARTIAL, not success" || bad "no PARTIAL marker: $out"
echo "$out" | grep -q 'index.html' && ok "names the failed file" || bad "failed file not listed"
snapid="$(echo "$out" | sed -n 's/.*rollback of snapshot \([A-Za-z0-9._-]*\).*/\1/p' | head -1)"
curl -s "${hdr[@]}" "$BASE?action=backups" | grep -q "\"id\":\"$snapid\"" \
    && ok "failed-rollback target snapshot survives for a retry" || bad "target snapshot was pruned away"
chk "partial rollback cleared the commit marker (forces --git resync)" "$(cur2=$(curl -s "${hdr[@]}" "$BASE?action=commit" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p'); echo "${cur2:-empty}")" "empty"
rm -rf "$ROOT/index.html"
run >/dev/null
chk "reconciled after cleanup" "$(sv index.html)" "U4"

echo "== --git rollback also restores the commit cursor =="
cur() { curl -s "${hdr[@]}" "$BASE?action=commit" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p'; }
gsv() { cat "$ROOT/$1" 2>/dev/null || true; }
( cd "$GP" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'DEPLOY_URL="%s"\nDEPLOY_TOKEN="%s"\n' "$BASE" "$TOKEN" > .deploy_secret \
  && printf 'g1\n' > gpage.html && git add gpage.html && git commit -qm c1 && "$CLIENT" --git --rehash >/dev/null 2>&1 )
H1="$( cd "$GP" && git rev-parse HEAD )"
chk "git deploy set cursor to c1" "$(cur)" "$H1"
sleep 1
( cd "$GP" && printf 'g2\n' > gpage.html && git commit -qm c2 gpage.html && "$CLIENT" --git >/dev/null 2>&1 )
H2="$( cd "$GP" && git rev-parse HEAD )"
chk "git deploy advanced cursor to c2" "$(cur)" "$H2"
( cd "$GP" && "$CLIENT" --git --rollback >/dev/null 2>&1 )
chk "rollback restored page content to g1" "$(gsv gpage.html)" "g1"
chk "rollback restored the commit cursor to c1" "$(cur)" "$H1"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
