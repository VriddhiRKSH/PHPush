# PHPush

**Git-style deploys for hosts that don't even give you FTP.**

PHPush pushes your local git working tree to a web host over plain HTTPS — no
FTP, no SSH, no shell on the server. You upload **one** small, token-protected
PHP file through whatever the host gives you (a cPanel/Plesk File Manager is
enough), and from then on a single local command mirrors your project up to it:
content-hash diff, only changed files, chunked uploads, atomic writes, and
deletion of files you removed — so the server always matches your working tree.

It needs nothing on the host but the ability to serve PHP. No git, no shell, no
`exec`, no FTP, no SFTP.

## Pieces

| File | Where it runs | Role |
|---|---|---|
| `phpush.php` | on the server (uploaded once) | **Receiver.** Token-gated endpoint that writes/deletes files. Deliberately dumb and auditable — it only moves bytes. |
| `phpush` | on your machine | **Client.** Mirrors the current git project to the receiver over HTTPS. All the intelligence (diffing, chunking, verification) lives here. |
| `.deploy_secret` | your project root (gitignored) | Your `DEPLOY_URL` + `DEPLOY_TOKEN`. |

## Requirements

- **Server:** any host that can execute PHP 7.0+. Nothing else.
- **Client:** `bash` (3.2+, so stock macOS works), `git`, `curl`, `base64`, and
  `shasum`/`sha1sum`.

## Setup

**1. Server (once):**
- Generate a token: `openssl rand -hex 32`
- Open `phpush.php` and paste that token into `DEPLOY_TOKEN` on line 3.
  (Or, if your host allows it, leave the source alone and set the `PHPUSH_TOKEN`
  environment variable instead — it takes precedence.)
- Upload `phpush.php` into the directory you want to deploy into, so it's
  reachable at e.g. `https://your-site.example/path/phpush.php`.
- Serve the site over **HTTPS** — the token travels in a request header. Also
  make sure the host actually executes `.php` (so the source, and your token,
  can't be downloaded). See [SECURITY.md](SECURITY.md).

**2. Project (once):**
- In the project you want to deploy, create `.deploy_secret` (and gitignore it):
  ```sh
  DEPLOY_URL="https://your-site.example/path/phpush.php"
  DEPLOY_TOKEN="<the same token>"
  ```
  (Copy `.deploy_secret.example` as a starting point. The file is **parsed, not
  executed** — only `DEPLOY_URL` and `DEPLOY_TOKEN` are read.)

## Use

```sh
cd /path/to/your-project
/path/to/PHPush/phpush --dry-run   # preview what would upload/delete
/path/to/PHPush/phpush             # mirror the working tree to the server
```

Tip: symlink it onto your `PATH` — `ln -s /path/to/PHPush/phpush /usr/local/bin/phpush` —
then just run `phpush` from any project.

### Two modes

- **Working-tree (default):** deploys what's in your folder right now — including
  uncommitted edits and new untracked files (anything not gitignored). Good for
  iterating fast.
- **Committed (`--git`):** deploys your **last commit** and ignores uncommitted
  changes. The server remembers the last commit it received, so each run sends
  only the files changed in the commits since then (a full resync happens
  automatically on the first run or if history was rewritten). Good for clean,
  reproducible releases.

  ```sh
  phpush --git            # deploy HEAD; only changed-since-last-deploy files go up
  phpush --git --dry-run  # preview
  ```

### Options

| Flag | Effect |
|---|---|
| `--git` | Deploy the last commit instead of the working tree (aliases: `--commit`, `--committed`). |
| `-n`, `--dry-run` | Show what would upload/delete; change nothing. |
| `--no-delete` | Upload changes but never delete server files. |
| `--rehash` | Working-tree: ignore the server's hash cache. `--git`: force a full resync. |
| `-h`, `--help` / `-V`, `--version` | Help / version. |

You can also override `DEPLOY_CHUNK_BYTES` (default `1048576`, i.e. 1 MB) if your
host's `post_max_size` is unusually small or large.

## How it stays safe

- **Token never leaks into logs or the process list.** It's sent only as a header
  over HTTPS (the client refuses non-HTTPS targets), passed to `curl` via a
  private config file, and never accepted in a URL.
- **Confined writes.** The receiver rejects `..`, absolute escapes, null bytes,
  and — via `realpath()` — symlinks that would write or delete outside its
  directory. It also protects itself from being overwritten or deleted, including
  case-folding tricks (`PHPUSH.PHP`) on macOS/Windows hosts.
- **Atomic, verified uploads.** Each file streams to a temp file and is renamed
  into place only when complete (no half-written files), then verified end-to-end
  by sha1. Large files are chunked to stay under PHP upload limits.

Full threat model and hardening checklist: **[SECURITY.md](SECURITY.md)**.

## Notes

- Only git-tracked (and untracked-but-not-ignored) files are deployed; ignored
  files and `.deploy_secret` never leave your machine.
- **Deploys mirror.** Files you removed locally are removed on the server (use
  `--no-delete` to keep them). The server ends up matching your working tree
  exactly — review `--dry-run` before the first run on an existing site.
- The server caches file hashes by size+mtime, so repeat deploys don't re-hash
  the whole tree. If you ever rewrite a file's contents without changing its size
  or mtime, run once with `--rehash`.
- To pause deploys, delete `phpush.php` from the server; re-upload to resume.

## Tests

```sh
tests/run.sh   # working-tree mode: security guards + full mirror
tests/git.sh   # --git mode: cursor, incremental, add/delete/rename, resync
```
Both spin up `php -S` locally and need no network. CI runs them on every push.

## License

[MIT](LICENSE) © 2026 Vriddhi RKSH
