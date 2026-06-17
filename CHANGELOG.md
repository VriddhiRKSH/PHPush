# Changelog

All notable changes to PHPush are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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

[0.4.1]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.4.1
[0.4.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.4.0
[0.3.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.3.0
[0.2.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.2.0
[0.1.0]: https://github.com/VriddhiRKSH/PHPush/releases/tag/v0.1.0
