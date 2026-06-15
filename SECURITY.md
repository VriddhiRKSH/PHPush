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
  Two hardening options are supported and recommended where possible:
  - Set the token via the `PHPUSH_TOKEN` environment variable instead of editing
    the source (takes precedence over the constant).
  - Block source disclosure. Make sure your host actually executes `.php` and
    can't serve it as text, and deny access to editor backups. An `.htaccess`
    for Apache:
    ```apache
    <FilesMatch "\.(bak|old|orig|save|swp|swo|tmp|php~|phps)$">
      Require all denied
    </FilesMatch>
    ```
- **sha1 verification proves transport/disk integrity, not authenticity.** The
  client checks that the bytes it sent are the bytes the server stored. A
  malicious server is out of scope (it already runs your code).

### Defended against

- **Unauthenticated access** — every action requires the token, checked with a
  constant-time comparison (`hash_equals`) before anything else runs.
- **Path traversal / escape** — request paths are sanitized (no `..`, no absolute
  escape, no null bytes) and confined with `realpath()` so a pre-existing
  **symlink** can't be used to write or delete outside the deploy directory.
- **Self-protection** — the receiver and its cache file cannot be overwritten or
  deleted through the endpoint, including via **case-folding tricks**
  (`PHPUSH.PHP`) on case-insensitive filesystems (macOS/Windows hosts).
- **Half-written files** — uploads are streamed to a temporary file and
  **atomically renamed** into place only when complete, so visitors never see a
  partially written file and a dropped connection can't truncate a live one.
- **Cleartext token leaks** — the client refuses non-HTTPS targets (except
  explicit localhost for testing), passes the token to `curl` via a private
  config file (never on the command line, so it isn't visible in the process
  list), and never accepts the token in a URL query string.

## Hardening checklist

- [ ] Generate a strong token: `openssl rand -hex 32`.
- [ ] Serve the receiver over **HTTPS** with a valid certificate.
- [ ] Confirm the host executes `.php` and won't serve the source as text.
- [ ] Restrict by IP if you can (`ALLOW_IPS` in `phpush.php`).
- [ ] Keep `.deploy_secret` gitignored and readable only by you (`chmod 600`).
- [ ] Remove `phpush.php` from the server when you're done deploying; re-upload to resume.
