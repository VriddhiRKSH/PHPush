# Changelog

All notable changes to PHPush are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.7.0] — 2026-08-21

A safety + speed release: the deploy path can no longer delete or overwrite
anything silently, a new `phpush doctor` verifies the whole setup, one project
can deploy to several sites, and re-deploys are dramatically faster. Client and
receiver should be upgraded together.

### Added
- **`phpush doctor`** — a read-only, end-to-end checkup of a live setup: HTTPS,
  the receiver actually *running* as PHP (a host that serves `phpush.php` as
  plain text publishes the deploy token — doctor detects this from a token-less
  probe and tells you to rotate), token acceptance, client/server version match,
  secret-file gitignore hygiene, host limits (PHP version, `post_max_size` vs
  chunk size, free disk) via a new `?action=status`, backup writability, and a
  web-exposure probe of `.phpush-backups/` for hosts that ignore `.htaccess`.
  Exits 0 when clean, 1 when problems are found.
- **Named targets: `--target <name>`.** Reads `.deploy_secret.<name>` (same
  parser, no new trust surface) so one project can deploy to staging and
  production. When named target files exist, a bare `phpush` refuses to guess
  and lists them; the resolved target is shown on the `Target :` line and in the
  delete confirmation. `--target` combined with `DEPLOY_URL`/`DEPLOY_TOKEN` env
  vars is refused rather than silently mixed.
- **Delete confirmation.** When a deploy would delete server files and stdin is
  an interactive terminal, the client now lists them and asks
  `Delete N file(s) from the live site and proceed? [y/N]` before anything is
  sent. `--yes`/`-y` skips the question; non-interactive runs (CI, cron) are
  unchanged. The plan summary also shows the total upload size.
- **Rollback can be undone.** Before applying a rollback the receiver snapshots
  the current state through the same backup machinery and reports the new
  snapshot id; the client prints `Undo this rollback: phpush --rollback <id>`.
  `--rollback --no-backup` skips the undo snapshot.
- **`?action=status`** (receiver): reports PHP version, `post_max_size` /
  `upload_max_filesize` in bytes, free disk space, backup enablement +
  writability, and the managed flag — powering doctor and the deploy preflight.
- **`--no-handshake`** escape hatch for hosts that block the identity check;
  deletes then require `--adopt`.

### Changed
- **The version handshake is now a hard stop.** Previously a failed or foreign
  reply was silently ignored — which also switched off the first-deploy delete
  guard. Now an unreachable server, a non-PHPush reply, PHP source served as
  text, a rejected token, and an unconfigured token each abort the run with a
  specific, actionable message before anything is uploaded or deleted.
- **The first-deploy delete guard fails closed.** It now fires whenever the
  server is not positively known to be PHPush-managed (previously only on an
  explicit "never deployed" answer, so an unverifiable server bypassed it).
- **~150× faster local hashing.** The client no longer starts one
  `shasum`/`sha1sum` process per file: one batched `stat` pass fingerprints the
  tree, a local size+mtime cache (`.git/phpush-hash-cache`) reuses hashes for
  unchanged files, and only the misses are hashed in a single batched process.
  Files modified in the same second as a cache write are always re-hashed, and
  `--rehash` now clears the local cache as well as the server's.
- **Deploys preflight the backup area.** A deploy that would snapshot aborts
  before the first byte if the server cannot write backups, and warns when
  chunks exceed the host's `post_max_size` (the classic mystery-413) or free
  disk looks too small for the upload.
- **Backups fail loudly (receiver).** Backup copy/mkdir results are no longer
  discarded: a file whose backup cannot be written is *not* overwritten
  (HTTP 500, file left untouched) and *not* deleted (reported per-file in the
  delete response). Previously a full disk or bad permissions meant the "safety
  net" silently didn't exist while the deploy went ahead.
- **Rollback reports partial failure.** A rollback that cannot restore or
  remove every file now answers HTTP 500 `partial rollback` with the exact
  failed paths (and the undo id); previously it skipped failures silently and
  answered `ok: true` with only counts.

### Fixed (from the pre-release adversarial review)
- **A malformed `DEPLOY_CHUNK_BYTES` (e.g. `2M`) no longer fakes a successful
  deploy.** Previously a php.ini-style value crashed the upload loop mid-flight
  in a way that skipped the failure accounting, printing "Done." and exiting 0
  while zero bytes reached the server. The value is now validated up front
  (whole number of bytes, > 0), and the final check counts uploads that actually
  completed rather than trusting the failure counter.
- **Upload errors now show the server's reason.** `push_chunk` no longer uses
  `curl -f` (which discarded the response body), so a fail-loud backup refusal,
  a 413, or any other server rejection prints the HTTP status and message
  instead of a bare `FAILED: file`.
- **`--list-backups` on a server with no snapshots** printed nothing and exited
  1 (a `grep` pipeline under `set -o pipefail`); it now prints "No rollback
  snapshots on the server yet." and exits 0.
- **The delete confirmation prompts on the terminal** (`/dev/tty`), so a run
  with stdout redirected to a log still shows the question instead of hanging
  invisibly; with no terminal it fails closed (aborts).
- **`--no-delete` no longer disarms the first-deploy guard.** Using the guard's
  own suggested escape hatch marked the server as "managed", so the *next* plain
  run could delete the pre-existing files without `--adopt`. Uploads from such a
  run now tell the receiver not to mark the directory adopted.
- **Rollback bookkeeping:** a rollback no longer evicts a real deploy snapshot
  to make room for its own undo snapshot (the snapshot being restored and the
  new undo are both protected from pruning, so a partial rollback can always be
  retried); a rollback that applied nothing leaves no empty undo snapshot; and a
  **partial** rollback clears the `--git` commit marker so the next `--git`
  deploy does a full resync instead of reporting "Already in sync" over drifted
  files.
- **The server's manifest hash cache got the same same-second guard as the
  client's** (generation stamp; entries whose mtime is within 2s are re-hashed),
  closing a race where the server could report a hash for content it no longer
  held. Old cache files are rebuilt once, harmlessly.
- **`?action=status` reports `backups_on_disk`**, and doctor probes backup-folder
  web exposure even when `MAX_BACKUPS = 0` but old snapshots remain on disk.
- **All receiver responses now send `Cache-Control: no-store, private`** so an
  intermediary cache can never replay manifest/status data to someone without
  the token.
- **`--git` full resync fails closed on case-insensitive disks** when two
  committed paths collide on the local filesystem (previously one file's bytes
  silently deployed under both names).
- **Honest `--no-delete` reporting** in working-tree mode: "Done (uploads only)
  … Re-run without --no-delete to reconcile" instead of claiming the server
  mirrors the working tree.
- **Backslash filenames no longer deploy to the wrong path.** The receiver
  normalizes `\` to `/`, so a file literally named `back\slash.txt` was written
  to a `back/` *subdirectory* on the server and the mirror never converged. The
  client now skips `\` names with a warning (like `:` names) and refuses to
  send deletes for them.
- **`.deploy_secret.*` files are excluded everywhere.** The secret exclusion now
  covers named-target files in both modes, including the `--git` incremental
  rename/copy paths, which previously did not check secret names at all.

## [0.6.0] — 2026-07-03

### Added
- **Server-side backups + `--rollback`.** Every deploy now snapshots the files it
  is about to change: overwritten files are copied aside, deleted files are moved
  into the snapshot, and newly-created files are recorded — so a snapshot is a
  complete before-image of that deploy. `phpush --rollback` restores the latest
  snapshot (or `phpush --rollback <id>` a specific one), undoing that deploy
  exactly — overwritten/deleted files come back and files it added are removed —
  with zero re-upload. `--rollback --dry-run` previews the counts; the pre-deploy
  commit cursor is saved and restored so a `--git` rollback stays consistent.
- **`--list-backups`** lists the server's snapshots (newest first).
- **`--no-backup`** skips snapshotting a given deploy.
- Snapshots live under a protected `.phpush-backups/` (rejected from push/delete,
  hidden from the manifest, `.htaccess`-denied), bounded by the receiver's
  `MAX_BACKUPS` (default 10, `0` disables backups entirely) with oldest-first
  pruning by creation time.

Client and receiver should be upgraded together; the client warns on a version
mismatch (backups need the 0.6.0 receiver).

## [0.5.0] — 2026-07-03

A correctness + hardening release acting on a full multi-lens review, plus two
adoption features. Client and receiver should be upgraded together (the client
now warns on a version mismatch).

### Security
- **Token-exfiltration fix (client).** The cleartext-`http` localhost exception
  used unanchored globs, so `http://127.0.0.1@evil.example/…` and
  `http://127.0.0.1.evil.example/…` slipped through as "localhost (testing only)"
  and sent the deploy token to a remote host in the clear. The client now parses
  the authority, rejects `@`-userinfo, and matches the localhost host exactly.
- **Chunk-offset integrity (receiver).** Uploads carry `X-Deploy-Offset`; the
  receiver verifies it against the current temp size before appending, so a stale
  `.phpush-tmp` can no longer be concatenated into a file that then reports a
  valid sha1. Interrupted uploads are now safely resumable.

### Fixed
- **Nested files sharing a reserved basename** (`libs/phpush.php`,
  `vendor/x/phpush.php`) were rejected on push and hidden from the manifest, so
  the deploy could never reach sync. Self-protection is now scoped to the deploy
  root; the `realpath` identity check still guards the real receiver/state files.
- **`--git --no-delete` no longer poisons the commit cursor.** It kept the marker
  where it was reporting sync while the removed files were still on the server; a
  later `--git` run then never reconciled them. The cursor now stays put when
  deletes are suppressed, so a normal run reconciles them.
- **Deterministic `--git` mirror.** Full resync used `git archive|tar` (honoring
  `export-ignore`, materializing symlinks) while incremental used `git diff`/`git
  show` (honoring neither), so the same commit could deploy a different tree. Both
  now deploy exactly `git ls-tree -r HEAD`, skip symlinks/submodules
  consistently, and no longer need `tar`.
- **Partial-delete (`207`) failures are surfaced.** The client treated `207` as
  success and (in `--git`) advanced the cursor past deletes the server rejected;
  it now reports them, leaves the cursor, and exits non-zero.
- **Legacy state cleanup no longer deletes user files.** The v0.3→v0.4 cleanup
  unconditionally removed any `.phpush-cache.json` / `.phpush-commit`; it now only
  removes files matching the legacy format when the new-format state exists.
- **Delete-path parity.** Delete paths (incl. rename old-paths) are validated for
  `:`/control chars like uploads, instead of silently dropping.
- **One non-UTF-8 filename** no longer voids the entire manifest cache (only that
  path is skipped from caching), and multi-chunk uploads report the full byte
  count.
- **`.deploy_secret` parsing** tolerates indentation, `export`, CRLF, and
  trailing whitespace.

### Added
- **`?action=version` handshake** — reports the receiver version and whether
  PHPush has deployed here; the client warns on version skew.
- **First-deploy `--adopt` guard** — the client refuses a first deploy that would
  delete pre-existing files on an unmanaged server unless you pass `--adopt`
  (take over) or `--no-delete` (add alongside).
- **`.pushignore`** — a deploy-only exclude list (practical glob subset) that
  keeps files out of the published tree in both modes without touching git.

## [0.4.1] — 2026-06-17

### Fixed
- **Client/server parity on `:`** — the client now skips a filename containing a
  colon (legal on macOS/Linux, rejected by the receiver as an NTFS-stream guard)
  with a clear warning, instead of marching to the server and failing the whole
  deploy with a cryptic error.
- **Legacy state cleanup** — the receiver removes any old unguarded
  `.phpush-cache.json` / `.phpush-commit` left over from a pre-0.4.0 install, so an
  in-place upgrade can't leave a web-readable inventory file behind.

### Security
- **CI actions are SHA-pinned** (`actions/checkout`, `shivammathur/setup-php`) so a
  hijacked moving tag can't run untrusted code in CI.

## [0.4.0] — 2026-06-17

A security-hardening release acting on an external review. Each fix has a
regression test in `tests/security.sh`.

### Security
- **Metadata privacy (the one unauthenticated leak):** the receiver's cache and
  commit-cursor files are now stored as self-guarding PHP files
  (`.phpush-cache.php`, `.phpush-commit.php`) that emit nothing if fetched
  directly — so a normal web server can no longer hand the site's file inventory,
  hashes, or deployed commit to a tokenless visitor.
- **`--git` no longer wipes the server** on a commit that resolves to zero
  deployable files — it refuses, matching working-tree mode's empty-tree guard.
- **Untrusted-repo hardening (client):** refuses a committed `.deploy_secret`,
  **skips symlinks** instead of following them (no `~/.ssh/id_rsa` exfiltration),
  rejects a newline-bearing token (curl-config injection), and skips a nested
  `.deploy_secret` at any depth.
- **Receiver path guards:** rejects control characters and `:` / NTFS `::$DATA`
  stream syntax; `MAX_PUSH_BYTES` is now enforced cumulatively across chunked
  appends; commit file gets full `realpath` self-protection; `X-Content-Type-Options:
  nosniff` on all responses.
- **CI** now runs with least-privilege `permissions: contents: read`.

### Docs
- SECURITY.md documents shared-host token reads, the `ALLOW_IPS`-behind-proxy
  caveat, token-entropy guidance, and "your .gitignore is the secrets safety net."

## [0.3.0] — 2026-06-16

### Added
- **`--git` committed-deploy mode** (aliases `--commit`, `--committed`): deploys
  your last commit instead of the working tree, ignoring uncommitted changes.
- **Server-side commit cursor** (`?action=commit`): the receiver remembers the
  last commit it received in a protected, manifest-excluded `.phpush-commit`, so
  `--git` sends only the files changed since the previous deploy
  (`git diff LAST..HEAD`).
- **Automatic full resync** on the first `--git` run, after a rewritten history,
  or with `--rehash`, staged via `git archive`.
- A second test suite, `tests/git.sh` (21 checks); CI now runs both suites.

## [0.2.0] — 2026-06-16

A full adversarial security/quality/performance review and hardening pass.

### Security
- Removed the `?token=` URL fallback — the token is accepted only via the
  `X-Deploy-Token` header (keeps it out of access/proxy logs).
- `realpath()` confinement so a pre-existing symlink can't make a push or delete
  escape the deploy directory.
- Self-protection now resists case-folding (`PHPUSH.PHP`) on case-insensitive
  filesystems, for the receiver and its cache file.
- Client refuses non-HTTPS targets (except explicit localhost), passes the token
  to curl via a private config file (never on the command line / process list),
  and **parses** `.deploy_secret` instead of sourcing it as shell.
- Rejects control-character paths that would corrupt the manifest or delete JSON.

### Added
- Atomic temp-then-rename writes — visitors never see a half-written file.
- Size+mtime manifest hash cache on the server (`--rehash` to bypass).
- `--no-delete` flag; `--version`.
- MIT `LICENSE`, `SECURITY.md`, a `tests/` suite over `php -S`, and GitHub
  Actions CI (`php -l` + shellcheck + integration tests).

### Fixed
- A failed upload now skips the destructive delete pass (no half-mirror).
- Leading-dash and other awkward filenames are handled safely.

## [0.1.0] — 2026-06-16

Initial extraction from the acica.es project into a standalone repo. Working
push-to-deploy mirror: token-gated PHP receiver plus a bash client that diffs by
content hash, uploads only changed files in chunks, verifies by sha1, and mirrors
deletions.

[0.6.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.6.0
[0.5.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.5.0
[0.4.1]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.4.1
[0.4.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.4.0
[0.3.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.3.0
[0.2.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.2.0
[0.1.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.1.0
