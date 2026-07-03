# Changelog

All notable changes to PHPush are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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
