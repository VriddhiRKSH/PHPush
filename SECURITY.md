# Security Policy

PHPush installs a small, token-protected PHP endpoint (`phpush.php`) that can
**write and delete files** in its own directory over HTTPS. Treat it as a
privileged credential, not a toy. This document explains the threat model so you
can decide whether it's safe for your situation, and how to report problems.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for an
unpatched flaw, because every deployed receiver shares the same simple design.

- Use GitHub's **"Report a vulnerability"** (Security → Advisories) on this repo, or
- email the maintainer listed on the repository profile.

Include the affected file/line, a proof-of-concept, and the impact. We aim to
acknowledge within a few days and to ship a fix and credit you (unless you prefer
to stay anonymous).

## Threat model — what PHPush does and does not defend

The receiver's only authentication is a **shared bearer token**. The design is
deliberately minimal so the whole server-side surface fits on one screen and can
be audited.

### Accepted by design (not bugs)

- **A valid token is full control of the deploy directory.** The push action
  writes arbitrary bytes to any path inside the receiver's directory, including
  `.php`, `.htaccess`, and `.user.ini`. Anyone with the token can therefore run
  code on the site. **Protect the token like a password and serve only over
  HTTPS.** If it leaks, rotate it immediately (change `DEPLOY_TOKEN`) or delete
  `phpush.php` from the server.
- **The token lives in `phpush.php`'s source by default.** File-Manager-only
  hosts often can't set environment variables, so this is the pragmatic default.
  Its confidentiality then depends on nothing being able to read that file's
  bytes — a serve-as-text misconfiguration, an editor backup, or a nosy neighbor
  on shared hosting reading your files. Harden where you can:
  - Set the token via the `PHPUSH_TOKEN` environment variable instead of editing
    the source (takes precedence over the constant). Best option if your host
    allows env vars.
  - On shared hosting, make `phpush.php` readable only by you/the web user
    (`chmod 600 phpush.php` via the File Manager) so other accounts on the box
    can't read the token.
  - Block source disclosure. Make sure your host actually executes `.php` and
    can't serve it as text, and deny access to editor backups (and dotfiles). An
    `.htaccess` for Apache:
    ```apache
    <FilesMatch "\.(bak|old|orig|save|swp|swo|tmp|php~|phps)$">
      Require all denied
    </FilesMatch>
    # Optional belt-and-suspenders: deny PHPush's own metadata dotfiles
    <FilesMatch "^\.phpush-">
      Require all denied
    </FilesMatch>
    ```
- **sha1 verification proves transport/disk integrity, not authenticity.** The
  client checks that the bytes it sent are the bytes the server stored. A
  malicious server is out of scope (it already runs your code).

### Defended against

- **Unauthenticated access** — every action requires the token, checked with a
  constant-time comparison (`hash_equals`) before anything else runs.
- **Metadata disclosure** — the receiver's bookkeeping files (`.phpush-cache.php`,
  `.phpush-commit.php`) are stored as PHP files that emit nothing if fetched
  directly (`<?php http_response_code(404); exit;`), so even on a host that serves
  dotfiles they cannot leak the site's file inventory, hashes, or deployed commit
  to an unauthenticated visitor.
- **Path traversal / escape** — request paths are sanitized (no `..`, no absolute
  escape, no null bytes, no control characters, no `:` / NTFS stream syntax) and
  confined with `realpath()` so a pre-existing **symlink** can't be used to write
  or delete outside the deploy directory.
- **Self-protection** — the receiver and its cache/commit files cannot be
  overwritten or deleted through the endpoint, including via **case-folding tricks**
  (`PHPUSH.PHP`) on case-insensitive filesystems (macOS/Windows hosts).
- **Half-written files** — uploads are streamed to a temporary file and
  **atomically renamed** into place only when complete, so visitors never see a
  partially written file and a dropped connection can't truncate a live one. An
  optional `MAX_PUSH_BYTES` cap is enforced cumulatively across chunked appends.
- **Cleartext token leaks** — the client refuses non-HTTPS targets (except
  explicit localhost for testing), passes the token to `curl` via a private
  config file (never on the command line, so it isn't visible in the process
  list), never accepts the token in a URL query string, and rejects a token
  containing newlines (which could inject curl directives).
- **Untrusted-repo safety (client)** — running `phpush` inside a hostile repo is
  guarded: it **refuses** a `.deploy_secret` that's been committed to the repo
  (yours should be gitignored), and it **skips symlinks** rather than following
  them, so a symlink pointing at `~/.ssh/id_rsa` can't be uploaded. Still, prefer
  not to run a deploy tool inside a repository you don't trust.

### Operational caveats (your responsibility)

- **Your `.gitignore` is the safety net for secrets.** PHPush mirrors everything
  that isn't gitignored, so a tracked or untracked-but-not-ignored `.env`,
  `*.sql` dump, `composer.lock`, `tests/`, or `.github/` will be published to the
  public web root. Review `phpush --dry-run` before the first deploy, and gitignore
  anything that shouldn't be public. (A `.pushignore` exclude list is on the
  roadmap.)
- **`ALLOW_IPS` uses `REMOTE_ADDR`.** That's correct on a normal server, but
  behind Cloudflare or any reverse proxy `REMOTE_ADDR` is the *proxy's* address —
  so the allowlist will either block everyone or effectively trust everyone. Treat
  the token, not the IP list, as the real gate.
- **Token strength is on you.** The receiver only checks the token is ≥ 32 chars
  and there is no rate-limiting, so a weak token (e.g. `aaaa…`) is guessable.
  Always generate it with `openssl rand -hex 32`.

## Hardening checklist

- [ ] Generate a strong token: `openssl rand -hex 32` (not a guessable string).
- [ ] Serve the receiver over **HTTPS** with a valid certificate.
- [ ] Confirm the host executes `.php` and won't serve the source as text.
- [ ] On shared hosting, `chmod 600 phpush.php` so neighbors can't read the token.
- [ ] Restrict by IP if you can (`ALLOW_IPS`) — but not if you're behind a proxy/CDN.
- [ ] Keep `.deploy_secret` gitignored and readable only by you (`chmod 600`).
- [ ] Gitignore any secrets (`.env`, DB dumps) so the mirror can't publish them.
- [ ] Remove `phpush.php` from the server when you're done deploying; re-upload to resume.
