# PHPush

[![CI](https://github.com/VriddhiRKSH/PHPush/actions/workflows/ci.yml/badge.svg)](https://github.com/VriddhiRKSH/PHPush/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**`git push`-style deploys for any host that runs PHP — over plain HTTPS.**

PHPush mirrors your local project to a web host with a single command:
content-hash diff, only changed files uploaded, chunked uploads, atomic writes,
and deletion of files you removed — so the server always matches your project.
The whole transport is one small, token-protected PHP file you drop on the host
once; from then on `phpush` feels like pushing to a remote.

It needs nothing on the host but the ability to serve PHP. No git, no shell, no
`exec`, no FTP, no SFTP.

### Who it's for

- **You only have a File Manager.** Cheap/locked-down shared hosting (often a
  client's cPanel/Plesk) can give you *only* a web File Manager — no FTP, no
  SFTP, no SSH. PHPush is the rescue tool: upload one file through the browser
  and you have push-to-deploy where there was none.
- **You'd rather not touch FTP.** Even if the host offers SFTP, you may not want
  to wire up an FTP client, juggle credentials, or drag files by hand. PHPush is
  one command over HTTPS you already trust for the site.
- **You want a `git push` feel on cheap hosting.** No CI runner, no SSH keys, no
  Deployer/Capistrano setup — just `phpush` (working tree) or `phpush --git`
  (your last commit) and the site updates incrementally.

If your host gives you SFTP and you're happy with a mature FTP deployer
(`git-ftp`, PHPloy), those are great too — PHPush's niche is *no transport but
PHP*, and *preferring a single push command* to anything heavier.

## Demo

```console
$ phpush --dry-run
Target : https://your-site.example/path/phpush.php
Upload : 4   Delete: 0

— to upload —
  + css/site.css
  + index.html
  + js/app.js
  + robots.txt

(dry run — nothing sent)

$ phpush
Target : https://your-site.example/path/phpush.php
Upload : 4   Delete: 0
...
  uploaded 4/4 file(s)
Done. The server now mirrors your working tree.

$ phpush                       # nothing changed → cheap content-hash diff
Already in sync. Nothing to do.
```

Deploy a clean release straight from your last commit instead (ignores
uncommitted edits; sends only what changed since the previous deploy):

```console
$ phpush --git
Target : https://your-site.example/path/phpush.php
Mode   : git (incremental) — commit 79885368da
Since  : b21c334f18
Upload : 2   Delete: 0

— to upload —
  + app.js
  + css/site.css

  uploaded 2/2 file(s)
Done. The server now matches commit 79885368da.
```

## Pieces

| File | Where it runs | Role |
|---|---|---|
| `phpush.php` | on the server (uploaded once) | **Receiver.** Token-gated endpoint that writes/deletes files. Deliberately dumb and auditable — it only moves bytes. |
| `phpush` | on your machine | **Client.** Mirrors the current git project to the receiver over HTTPS. All the intelligence (diffing, chunking, verification) lives here. |
| `.deploy_secret` | your project root (gitignored) | Your `DEPLOY_URL` + `DEPLOY_TOKEN`. |
| `.pushignore` | your project root (optional) | Globs to keep out of the deploy (not uploaded, not deleted). |

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

## Install (make `phpush` a global command)

`phpush` is a plain bash script — **nothing to build or compile.** To run it as a
bare `phpush` from any project, symlink it onto your `PATH` (from inside the PHPush
repo):

```sh
ln -s "$(pwd)/phpush" /usr/local/bin/phpush
# Apple-Silicon Homebrew users may prefer:  ln -s "$(pwd)/phpush" /opt/homebrew/bin/phpush
```

Because it's a **symlink**, you never reinstall: a `git pull` or any local edit to
the script is picked up automatically the next time you run `phpush`. (If you
*copy* the file instead of symlinking, re-copy it after each update.) To remove it
later: `rm /usr/local/bin/phpush`.

## Use

```sh
cd /path/to/your-project
phpush --dry-run   # preview what would upload/delete (changes nothing)
phpush             # deploy: mirror your working tree to the server
```

### Two modes — working tree vs. committed

| | `phpush` (default) | `phpush --git` |
|---|---|---|
| **Deploys** | your folder **right now** (committed + uncommitted + untracked, minus gitignored) | your **last commit** only (uncommitted & untracked ignored) |
| **Sends** | files whose content differs from the server | files changed in commits since the last `--git` deploy |
| **Best for** | fast iteration | clean, reproducible releases |
| **Tracks a commit?** | no | yes — the server remembers the last deployed commit |

```sh
phpush                  # deploy whatever is in my folder now
phpush --git            # deploy my last commit; only changed-since-last files go up
phpush --git --dry-run  # preview either mode
```

The first `--git` run (or one after a rewritten history, or with `--rehash`) does a
**full resync** — it deploys the whole committed snapshot and mirrors it. After
that, each run is **incremental**.

**Mixing the two modes? Know this:** default mode pushes uncommitted edits live and
never moves the commit marker. If you then run `phpush --git`, its incremental mode
only re-sends files that have a **new commit** — so an uncommitted change you pushed
with default mode, for a file that wasn't later committed, will **stay** on the
server. To force the server back to an exact copy of your last commit (cleaning up
any such drift and removing non-committed files):

```sh
phpush --git --rehash
```

Simplest habit: **pick one mode per project** — default for iterating, `--git` for
releases. These exact interactions are pinned down in `tests/modes.sh`.

### Options

| Flag | Effect |
|---|---|
| `--git` | Deploy the last commit instead of the working tree (aliases: `--commit`, `--committed`). |
| `-n`, `--dry-run` | Show what would upload/delete; change nothing. |
| `--no-delete` | Upload changes but never delete server files. |
| `--adopt` | Allow a **first** deploy to delete pre-existing files on a server PHPush has never deployed to (needed to take over an existing site — see below). |
| `--rehash` | Working-tree: ignore the server's hash cache. `--git`: force a full resync. |
| `-h`, `--help` / `-V`, `--version` | Help / version. |

You can also override `DEPLOY_CHUNK_BYTES` (default `1048576`, i.e. 1 MB) if your
host's `post_max_size` is unusually small or large.

### Deploying to a site that already has files (`--adopt`)

Because deploys **mirror**, the first run against a directory that already has
content would delete everything not in your project. PHPush guards against this:
it remembers when it has deployed to a server, and if the **first** deploy would
delete pre-existing files, it stops and asks you to choose:

```console
$ phpush
error: the server has 12 file(s) PHPush has never deployed, and this run would
       DELETE them to mirror your project.
       To take over this directory (this WILL delete those files):  re-run with --adopt
       To upload without deleting anything:                         re-run with --no-delete
       To review exactly what would change first:                   phpush --dry-run
```

Run `phpush --dry-run` to see the plan, then `--adopt` to take over or
`--no-delete` to add your files alongside the existing ones.

### Excluding files from deploy (`.pushignore`)

Your `.gitignore` controls what leaves your machine, but sometimes you want files
in git that shouldn't be *published* — `tests/`, `.github/`, raw sources, a
`README`. Add a `.pushignore` at your project root (one glob per line):

```gitignore
# never deploy these
*.log
tests/
.github/
node_modules/
README.md
```

Matched files are neither uploaded nor deleted, in both modes. `.pushignore` and
`.deploy_secret` are always excluded. (Supported globs are a practical subset:
`*.log`, `dir/`, and `path/*.css` — not the full `.gitignore` grammar.)

## How it stays safe

- **Token never leaks into logs or the process list.** It's sent only as a header
  over HTTPS (the client refuses non-HTTPS targets, rejecting `@`-userinfo and
  look-alike-host tricks so `http://127.0.0.1@evil.example` can't smuggle it to a
  remote host), passed to `curl` via a private config file, and never in a URL.
- **Confined writes.** The receiver rejects `..`, absolute escapes, null bytes,
  and — via `realpath()` — symlinks that would write or delete outside its
  directory. It also protects itself from being overwritten or deleted, including
  case-folding tricks (`PHPUSH.PHP`) on macOS/Windows hosts.
- **Atomic, verified uploads.** Each file streams to a temp file and is renamed
  into place only when complete (no half-written files), then verified end-to-end
  by sha1. Chunk offsets are checked so a stale temp can't corrupt a file. Large
  files are chunked to stay under PHP upload limits.
- **No accidental first-run wipe.** A version/status handshake lets the client
  detect a server it has never deployed to and refuse to delete pre-existing
  files without `--adopt` (see above).

Full threat model and hardening checklist: **[SECURITY.md](SECURITY.md)**.

## Notes

- Only git-tracked (and untracked-but-not-ignored) files are deployed; ignored
  files, `.pushignore` matches, and `.deploy_secret` never leave your machine.
- **Your `.gitignore` is your secrets safety net.** Anything not gitignored (and
  not `.pushignore`d) gets published to the public web root — so gitignore secrets
  like `.env` and DB dumps, and run `--dry-run` before the first deploy to a real
  site. PHPush also skips symlinks and refuses a `.deploy_secret` you've
  accidentally committed.
- **Deploys mirror.** Files you removed locally are removed on the server (use
  `--no-delete` to keep them). The server ends up matching your working tree
  exactly. The first deploy to a directory that already has files needs `--adopt`
  (or `--no-delete`) — review `--dry-run` first.
- Keep the client (`phpush`) and receiver (`phpush.php`) on the **same version**;
  the client prints a note if they differ. Re-upload `phpush.php` after upgrading.
- The server caches file hashes by size+mtime, so repeat deploys don't re-hash
  the whole tree. If you ever rewrite a file's contents without changing its size
  or mtime, run once with `--rehash`.
- To pause deploys, delete `phpush.php` from the server; re-upload to resume.

## Tests

```sh
tests/run.sh        # working-tree mode: security guards + full mirror
tests/git.sh        # --git mode: cursor, incremental, add/delete/rename, resync
tests/modes.sh      # mixing the two modes: uncommitted vs committed, drift, --rehash
tests/security.sh   # hardening regressions: metadata privacy, path guards, no-wipe, exfil
```
Each spins up `php -S` locally and needs no network. CI runs all four (plus
`php -l` and `shellcheck`) on every push.

## Changelog & security

Release notes live in [CHANGELOG.md](CHANGELOG.md). The threat model and how to
report a vulnerability are in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Vriddhi RKSH
