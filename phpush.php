<?php

const PHPUSH_VERSION = '0.7.0';
const DEPLOY_TOKEN = '__PASTE_64_HEX_TOKEN_HERE__';
const ALLOW_IPS = [];
const MAX_PUSH_BYTES = 0;

const CACHE_FILE = '.phpush-cache.php';
const COMMIT_FILE = '.phpush-commit.php';
const DEPLOYED_FILE = '.phpush-deployed.php';
const BACKUP_DIR = '.phpush-backups';
const MAX_BACKUPS = 10;
const TMP_SUFFIX = '.phpush-tmp';
const STATE_GUARD = "<?php http_response_code(404); exit; ?>\n";

$root = rtrim(str_replace('\\', '/', __DIR__), '/');
$realRoot = realpath($root);
$realRoot = $realRoot === false ? $root : str_replace('\\', '/', $realRoot);

$self = basename(__FILE__);
$protectedLower = array_map('strtolower', [$self, CACHE_FILE, COMMIT_FILE, DEPLOYED_FILE]);

$selfReal = realpath(__FILE__);
$selfReal = $selfReal === false ? '' : strtolower(str_replace('\\', '/', $selfReal));
$cacheReal = realpath($root . '/' . CACHE_FILE);
$cacheReal = $cacheReal === false ? '' : strtolower(str_replace('\\', '/', $cacheReal));
$commitReal = realpath($root . '/' . COMMIT_FILE);
$commitReal = $commitReal === false ? '' : strtolower(str_replace('\\', '/', $commitReal));

function resolve_token() {
    $env = getenv('PHPUSH_TOKEN');
    if (is_string($env) && $env !== '') return $env;
    return DEPLOY_TOKEN;
}

function respond($code, array $payload) {
    http_response_code($code);
    header('Content-Type: application/json');
    header('Cache-Control: no-store, private');
    header('Vary: X-Deploy-Token');
    header('X-Content-Type-Options: nosniff');
    header('X-Robots-Tag: noindex, nofollow');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function respond_text($code, $body) {
    http_response_code($code);
    header('Content-Type: text/plain; charset=utf-8');
    header('Cache-Control: no-store, private');
    header('Vary: X-Deploy-Token');
    header('X-Content-Type-Options: nosniff');
    header('X-Robots-Tag: noindex, nofollow');
    echo $body;
    exit;
}

function read_token() {
    if (isset($_SERVER['HTTP_X_DEPLOY_TOKEN'])) return (string) $_SERVER['HTTP_X_DEPLOY_TOKEN'];
    return '';
}

function state_read($path) {
    if (!is_file($path)) return '';
    $raw = @file_get_contents($path);
    if ($raw === false) return '';
    return preg_replace('/^<\?php.*?\?>\r?\n?/s', '', $raw, 1);
}

function state_write($path, $payload) {
    $tmp = $path . TMP_SUFFIX;
    if (@file_put_contents($tmp, STATE_GUARD . $payload, LOCK_EX) === false) return false;
    if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
    @chmod($path, 0600);
    return true;
}

function safe_target($root, $rel) {
    if (!is_string($rel) || $rel === '' || preg_match('/[\x00-\x1f]/', $rel)) return false;
    $rel = str_replace('\\', '/', $rel);
    $parts = [];
    foreach (explode('/', $rel) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') return false;
        if (strpos($part, ':') !== false) return false;
        $parts[] = $part;
    }
    if (!$parts) return false;
    if (strtolower($parts[0]) === strtolower(BACKUP_DIR)) return false;
    return $root . '/' . implode('/', $parts);
}

function is_reserved_name($name) {
    $bn = rtrim(strtolower(basename($name)), " .");
    if ($bn === '') return false;
    if (strlen($bn) >= strlen(TMP_SUFFIX) && substr($bn, -strlen(TMP_SUFFIX)) === TMP_SUFFIX) return true;
    return false;
}

function is_protected_target($target, $root, array $protectedLower, $selfReal, $cacheReal, $commitReal) {
    $bn = rtrim(strtolower(basename($target)), " .");
    $parent = rtrim(str_replace('\\', '/', dirname($target)), '/');
    $rootNorm = rtrim(str_replace('\\', '/', $root), '/');
    if ($parent === $rootNorm && in_array($bn, $protectedLower, true)) return true;
    if (is_reserved_name($target)) return true;
    $rt = realpath($target);
    if ($rt !== false) {
        $rt = strtolower(str_replace('\\', '/', $rt));
        if ($rt === $selfReal) return true;
        if ($cacheReal !== '' && $rt === $cacheReal) return true;
        if ($commitReal !== '' && $rt === $commitReal) return true;
    }
    return false;
}

function confined_dir($dir, $realRoot) {
    $real = realpath($dir);
    if ($real === false) return false;
    $real = str_replace('\\', '/', $real);
    if ($real === $realRoot) return $real;
    if (strpos($real, $realRoot . '/') === 0) return $real;
    return false;
}

function nearest_existing($dir) {
    while (!is_dir($dir)) {
        $parent = dirname($dir);
        if ($parent === $dir) break;
        $dir = $parent;
    }
    return $dir;
}

function b64url_decode($value) {
    if (!is_string($value) || $value === '') return '';
    $value = strtr($value, '-_', '+/');
    $pad = strlen($value) % 4;
    if ($pad) $value .= str_repeat('=', 4 - $pad);
    $decoded = base64_decode($value, true);
    return $decoded === false ? '' : $decoded;
}

function list_files($root) {
    $out = [];
    if (!is_dir($root)) return $out;
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::LEAVES_ONLY
    );
    foreach ($iterator as $file) {
        if (!$file->isFile() || $file->isLink()) continue;
        $rel = substr(str_replace('\\', '/', $file->getPathname()), strlen($root) + 1);
        if ($rel === '') continue;
        if ($rel === BACKUP_DIR || strncmp($rel, BACKUP_DIR . '/', strlen(BACKUP_DIR) + 1) === 0) continue;
        $out[] = $rel;
    }
    return $out;
}

function prune_empty_dirs($dir, $root) {
    $root = rtrim(str_replace('\\', '/', $root), '/');
    $dir = str_replace('\\', '/', $dir);
    while ($dir !== $root && strpos($dir, $root . '/') === 0) {
        if (!is_dir($dir)) break;
        $entries = @scandir($dir);
        if ($entries === false) break;
        if (count(array_diff($entries, ['.', '..'])) > 0) break;
        if (!@rmdir($dir)) break;
        $dir = dirname($dir);
    }
}

function looks_like_legacy_cache($raw) {
    if (!is_string($raw) || $raw === '' || $raw[0] === '<') return false;
    $d = json_decode($raw, true);
    if (!is_array($d) || $d === []) return false;
    foreach ($d as $v) {
        if (!is_array($v) || !array_key_exists('k', $v) || !array_key_exists('h', $v)) return false;
    }
    return true;
}

function mark_deployed($root) {
    $path = $root . '/' . DEPLOYED_FILE;
    if (!is_file($path)) state_write($path, '1');
}

function cleanup_legacy_state($root) {
    $cacheLegacy  = $root . '/.phpush-cache.json';
    $commitLegacy = $root . '/.phpush-commit';
    if (is_file($root . '/' . CACHE_FILE) && is_file($cacheLegacy)
        && looks_like_legacy_cache(@file_get_contents($cacheLegacy))) {
        @unlink($cacheLegacy);
    }
    if (is_file($root . '/' . COMMIT_FILE) && is_file($commitLegacy)) {
        $c = trim((string) @file_get_contents($commitLegacy));
        if ($c !== '' && preg_match('/^[0-9a-f]{40,64}$/', $c)) @unlink($commitLegacy);
    }
}

function valid_snapshot_id($id) {
    return is_string($id) && $id !== '' && strpos($id, '..') === false
        && preg_match('/^[A-Za-z0-9._-]{1,64}$/', $id) === 1;
}

function read_snapshot_id() {
    $s = $_SERVER['HTTP_X_DEPLOY_SNAPSHOT'] ?? '';
    return valid_snapshot_id($s) ? $s : '';
}

function list_snapshots($root) {
    $dir = $root . '/' . BACKUP_DIR;
    if (!is_dir($dir)) return [];
    $items = [];
    foreach (@scandir($dir) ?: [] as $e) {
        if ($e === '.' || $e === '..') continue;
        if (valid_snapshot_id($e) && is_dir($dir . '/' . $e)) {
            $items[] = [$e, (int) @filemtime($dir . '/' . $e)];
        }
    }
    usort($items, function ($a, $b) {
        return $a[1] === $b[1] ? strcmp($a[0], $b[0]) : ($a[1] <=> $b[1]);
    });
    $ids = [];
    foreach ($items as $it) $ids[] = $it[0];
    return $ids;
}

function rrmdir($dir) {
    if (is_link($dir)) { @unlink($dir); return; }
    if (!is_dir($dir)) { @unlink($dir); return; }
    foreach (@scandir($dir) ?: [] as $e) {
        if ($e === '.' || $e === '..') continue;
        rrmdir($dir . '/' . $e);
    }
    @rmdir($dir);
}

function prune_snapshots($root, array $keep = []) {
    if (MAX_BACKUPS <= 0) return;
    $dir = $root . '/' . BACKUP_DIR;
    $ids = list_snapshots($root);
    $excess = count($ids) - MAX_BACKUPS;
    foreach ($ids as $sid) {
        if ($excess <= 0) break;
        if (in_array($sid, $keep, true)) continue;
        rrmdir($dir . '/' . $sid);
        $excess--;
    }
}

function ensure_backups_root($root) {
    $backupsRoot = $root . '/' . BACKUP_DIR;
    if (!is_dir($backupsRoot)) {
        @mkdir($backupsRoot, 0700, true);
        @file_put_contents($backupsRoot . '/.htaccess', "Require all denied\nDeny from all\n");
        @file_put_contents($backupsRoot . '/index.php', STATE_GUARD);
    }
    return is_dir($backupsRoot) && is_writable($backupsRoot) ? $backupsRoot : false;
}

function snapshot_dir($root, $snapshotId, $prune = true) {
    $backupsRoot = $root . '/' . BACKUP_DIR;
    $base = $backupsRoot . '/' . $snapshotId;
    if (is_dir($base)) return is_writable($base) ? $base : false;
    if (ensure_backups_root($root) === false) return false;
    @mkdir($base, 0700, true);
    if (!is_dir($base) || !is_writable($base)) return false;
    $commitSrc = $root . '/' . COMMIT_FILE;
    if (is_file($commitSrc)) @copy($commitSrc, $base . '/commit.php');
    if ($prune) prune_snapshots($root);
    return $base;
}

// Called at push finalize: preserve whatever is currently at $target before it is
// replaced. If nothing is there, record that this deploy created the file so a
// rollback removes it. Returns true when the state is captured (or no snapshot
// was requested), false when a required backup could not be written — callers
// must then leave the target untouched.
function backup_before_overwrite($root, $snapshotId, $rel, $target, $prune = true) {
    if (MAX_BACKUPS <= 0 || $snapshotId === '') return true;
    $base = snapshot_dir($root, $snapshotId, $prune);
    if ($base === false) return false;
    $dest = $base . '/data/' . $rel;
    $mark = $base . '/created/' . $rel;
    // First write wins: never clobber a path already captured in this snapshot,
    // so a reused snapshot id can't overwrite the true pre-snapshot state.
    if (is_file($dest) || is_file($mark)) return true;
    if (is_file($target) && !is_link($target)) {
        if (!@mkdir(dirname($dest), 0700, true) && !is_dir(dirname($dest))) return false;
        return (bool) @copy($target, $dest);
    }
    if (!@mkdir(dirname($mark), 0700, true) && !is_dir(dirname($mark))) return false;
    return (bool) @touch($mark);
}

// Called at delete: move the file into the snapshot instead of unlinking it, so
// the delete itself is the backup. Returns 'moved' when the file went into the
// snapshot, 'skip' when no backup is needed (backups off, or this path already
// captured — caller may plain-unlink), or 'fail' when a required backup could
// not be written — callers must then leave the target in place.
function backup_move_delete($root, $snapshotId, $rel, $target, $prune = true) {
    if (MAX_BACKUPS <= 0 || $snapshotId === '') return 'skip';
    $base = snapshot_dir($root, $snapshotId, $prune);
    if ($base === false) return 'fail';
    $dest = $base . '/data/' . $rel;
    $mark = $base . '/created/' . $rel;
    // First write wins: if this path was already captured in this snapshot, leave
    // that capture intact and let the caller plain-unlink the current file.
    if (is_file($dest) || is_file($mark)) return 'skip';
    if (!@mkdir(dirname($dest), 0700, true) && !is_dir(dirname($dest))) return 'fail';
    return @rename($target, $dest) ? 'moved' : 'fail';
}

function ini_bytes($value) {
    $value = trim((string) $value);
    if ($value === '') return -1;
    $n = (float) $value;
    switch (strtolower(substr($value, -1))) {
        case 'g': return (int) ($n * 1073741824);
        case 'm': return (int) ($n * 1048576);
        case 'k': return (int) ($n * 1024);
        default:  return (int) $n;
    }
}

function collect_rel_files($dir) {
    $out = [];
    if (!is_dir($dir)) return $out;
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::LEAVES_ONLY
    );
    foreach ($it as $f) {
        if (!$f->isFile() || $f->isLink()) continue;
        $rel = substr(str_replace('\\', '/', $f->getPathname()), strlen($dir) + 1);
        if ($rel !== '') $out[] = $rel;
    }
    return $out;
}

if (ALLOW_IPS && !in_array($_SERVER['REMOTE_ADDR'] ?? '', ALLOW_IPS, true)) {
    respond(403, ['ok' => false, 'error' => 'ip not allowed']);
}

$configuredToken = resolve_token();
if (strlen($configuredToken) < 32) {
    respond(500, ['ok' => false, 'error' => 'token not configured']);
}

$token = read_token();
if ($token === '' || !hash_equals($configuredToken, $token)) {
    respond(401, ['ok' => false, 'error' => 'unauthorized']);
}

cleanup_legacy_state($root);

$action = $_GET['action'] ?? '';

if ($action === 'version') {
    respond(200, [
        'ok' => true,
        'version' => PHPUSH_VERSION,
        'managed' => is_file($root . '/' . DEPLOYED_FILE),
    ]);
}

if ($action === 'status') {
    $backupsPresent = is_dir($root . '/' . BACKUP_DIR);
    $backupsWritable = null;
    if (MAX_BACKUPS > 0 || $backupsPresent) {
        $backupsRoot = ensure_backups_root($root);
        $probeOk = false;
        if ($backupsRoot !== false) {
            @file_put_contents($backupsRoot . '/probe.html', "phpush-probe\n");
            $probeOk = (@file_get_contents($backupsRoot . '/probe.html') === "phpush-probe\n");
        }
        if (MAX_BACKUPS > 0) $backupsWritable = ($backupsRoot !== false && $probeOk);
    }
    $free = function_exists('disk_free_space') ? @disk_free_space($root) : false;
    respond(200, [
        'ok' => true,
        'version' => PHPUSH_VERSION,
        'php' => PHP_VERSION,
        'managed' => is_file($root . '/' . DEPLOYED_FILE),
        'writable_root' => is_writable($root),
        'post_max_bytes' => ini_bytes(ini_get('post_max_size')),
        'upload_max_bytes' => ini_bytes(ini_get('upload_max_filesize')),
        'memory_limit' => (string) ini_get('memory_limit'),
        'disk_free_bytes' => $free === false ? -1 : (int) $free,
        'max_backups' => MAX_BACKUPS,
        'backups_on_disk' => $backupsPresent ? count(list_snapshots($root)) : 0,
        'backups_writable' => $backupsWritable,
    ]);
}

if ($action === 'manifest') {
    $cachePath = $root . '/' . CACHE_FILE;
    $cache = [];
    $gen = 0;
    if (empty($_GET['fresh'])) {
        $decoded = json_decode(state_read($cachePath), true);
        if (is_array($decoded) && isset($decoded['gen'], $decoded['files']) && is_array($decoded['files'])) {
            $gen = (int) $decoded['gen'];
            $cache = $decoded['files'];
        }
    }
    $now = time();
    $newCache = [];
    $lines = [];
    foreach (list_files($root) as $rel) {
        $isRootProtected = (strpos($rel, '/') === false) && in_array(strtolower($rel), $protectedLower, true);
        if ($isRootProtected || is_reserved_name($rel)) continue;
        $full = $root . '/' . $rel;
        $size = @filesize($full);
        $mtime = @filemtime($full);
        $key = $size . ':' . $mtime;
        if ($mtime !== false && ((int) $mtime + 2) <= $gen
            && isset($cache[$rel]['k'], $cache[$rel]['h']) && $cache[$rel]['k'] === $key) {
            $hash = $cache[$rel]['h'];
        } else {
            $hash = sha1_file($full);
            if ($hash === false) continue;
        }
        if (preg_match('//u', $rel)) $newCache[$rel] = ['k' => $key, 'h' => $hash];
        $lines[] = $hash . "\t" . $rel;
    }
    $enc = json_encode(['gen' => $now, 'files' => $newCache], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if ($enc !== false) state_write($cachePath, $enc);
    respond_text(200, $lines ? implode("\n", $lines) . "\n" : '');
}

if ($action === 'push') {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        respond(405, ['ok' => false, 'error' => 'method not allowed']);
    }
    $rel = b64url_decode($_SERVER['HTTP_X_DEPLOY_PATH'] ?? '');
    $target = safe_target($root, $rel);
    if ($target === false || is_protected_target($target, $root, $protectedLower, $selfReal, $cacheReal, $commitReal)) {
        respond(400, ['ok' => false, 'error' => 'rejected path']);
    }
    $append = (($_SERVER['HTTP_X_DEPLOY_MODE'] ?? 'w') === 'a');
    $final = (($_SERVER['HTTP_X_DEPLOY_FINAL'] ?? '') === '1');
    $dir = dirname($target);
    if (confined_dir(nearest_existing($dir), $realRoot) === false) {
        respond(400, ['ok' => false, 'error' => 'rejected path']);
    }
    if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
        respond(500, ['ok' => false, 'error' => 'mkdir failed']);
    }
    if (confined_dir($dir, $realRoot) === false || is_link($target)) {
        respond(400, ['ok' => false, 'error' => 'rejected path']);
    }
    $tmp = $target . TMP_SUFFIX;
    if (is_link($tmp)) @unlink($tmp);
    $existing = ($append && is_file($tmp)) ? (int) @filesize($tmp) : 0;
    if (isset($_SERVER['HTTP_X_DEPLOY_OFFSET'])) {
        $offset = (int) $_SERVER['HTTP_X_DEPLOY_OFFSET'];
        if ($offset !== ($append ? $existing : 0)) {
            @unlink($tmp);
            respond(409, ['ok' => false, 'error' => 'chunk offset mismatch']);
        }
    }
    $in = fopen('php://input', 'rb');
    $out = fopen($tmp, $append ? 'ab' : 'wb');
    if (!$in || !$out) {
        if ($in) fclose($in);
        if ($out) fclose($out);
        @unlink($tmp);
        respond(500, ['ok' => false, 'error' => 'open failed']);
    }
    $bytes = 0;
    $ok = true;
    $tooBig = false;
    while (!feof($in)) {
        $buf = fread($in, 65536);
        if ($buf === false) { $ok = false; break; }
        if ($buf === '') continue;
        $w = fwrite($out, $buf);
        if ($w === false) { $ok = false; break; }
        $bytes += $w;
        if (MAX_PUSH_BYTES > 0 && ($existing + $bytes) > MAX_PUSH_BYTES) { $ok = false; $tooBig = true; break; }
    }
    fclose($in);
    fclose($out);
    if (!$ok) {
        @unlink($tmp);
        respond($tooBig ? 413 : 500, ['ok' => false, 'error' => $tooBig ? 'too large' : 'write failed']);
    }
    if ($final) {
        $snapshotId = read_snapshot_id();
        if (!backup_before_overwrite($root, $snapshotId, $rel, $target)) {
            @unlink($tmp);
            respond(500, ['ok' => false, 'error' => 'backup failed (' . BACKUP_DIR . ' not writable, or disk full) — file left untouched']);
        }
        if (!@rename($tmp, $target)) {
            @unlink($tmp);
            respond(500, ['ok' => false, 'error' => 'finalize failed']);
        }
        @chmod($target, 0644);
        if (($_SERVER['HTTP_X_DEPLOY_NO_ADOPT'] ?? '') !== '1') mark_deployed($root);
        respond(200, [
            'ok' => true, 'path' => $rel, 'bytes' => $existing + $bytes,
            'sha1' => sha1_file($target),
            'backed_up' => (MAX_BACKUPS > 0 && $snapshotId !== ''),
        ]);
    }
    respond(200, ['ok' => true, 'path' => $rel, 'bytes' => $existing + $bytes, 'partial' => true]);
}

if ($action === 'delete') {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        respond(405, ['ok' => false, 'error' => 'method not allowed']);
    }
    $list = json_decode(file_get_contents('php://input'), true);
    $snapshotId = read_snapshot_id();
    $deleted = [];
    $errors = [];
    if (is_array($list)) {
        foreach ($list as $rel) {
            $target = safe_target($root, $rel);
            if ($target === false || is_protected_target($target, $root, $protectedLower, $selfReal, $cacheReal, $commitReal)) {
                $errors[] = 'bad delete: ' . (is_string($rel) ? $rel : 'non-string');
                continue;
            }
            if (confined_dir(dirname($target), $realRoot) === false) {
                $errors[] = 'bad delete: ' . (is_string($rel) ? $rel : 'non-string');
                continue;
            }
            if (is_file($target) || is_link($target)) {
                $removed = false;
                if (is_file($target) && !is_link($target)) {
                    $bk = backup_move_delete($root, $snapshotId, $rel, $target);
                    if ($bk === 'fail') {
                        $errors[] = 'backup failed — not deleted: ' . $rel;
                        continue;
                    }
                    $removed = ($bk === 'moved');
                }
                if (!$removed) $removed = @unlink($target);
                if ($removed) {
                    $deleted[] = $rel;
                    prune_empty_dirs(dirname($target), $root);
                } else {
                    $errors[] = 'delete failed: ' . $rel;
                }
            }
        }
    }
    if ($deleted) mark_deployed($root);
    respond(empty($errors) ? 200 : 207, ['ok' => empty($errors), 'deleted' => $deleted, 'errors' => $errors]);
}

if ($action === 'commit') {
    $commitPath = $root . '/' . COMMIT_FILE;
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
        $body = trim((string) file_get_contents('php://input'));
        if ($body !== '' && !preg_match('/^[0-9a-f]{40,64}$/', $body)) {
            respond(400, ['ok' => false, 'error' => 'bad commit id']);
        }
        if (!state_write($commitPath, $body)) {
            respond(500, ['ok' => false, 'error' => 'write failed']);
        }
        respond(200, ['ok' => true, 'commit' => $body]);
    }
    respond(200, ['ok' => true, 'commit' => trim(state_read($commitPath))]);
}

if ($action === 'backups') {
    $out = [];
    foreach (array_reverse(list_snapshots($root)) as $id) {
        $base = $root . '/' . BACKUP_DIR . '/' . $id;
        $out[] = [
            'id' => $id,
            'files' => count(collect_rel_files($base . '/data')) + count(collect_rel_files($base . '/created')),
        ];
    }
    respond(200, ['ok' => true, 'max' => MAX_BACKUPS, 'backups' => $out]);
}

if ($action === 'rollback') {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        respond(405, ['ok' => false, 'error' => 'method not allowed']);
    }
    $ids = list_snapshots($root);
    if (!$ids) {
        respond(404, ['ok' => false, 'error' => 'no backups to roll back to']);
    }
    $want = (string) ($_GET['snapshot'] ?? '');
    if ($want !== '') {
        if (!valid_snapshot_id($want) || !in_array($want, $ids, true)) {
            respond(404, ['ok' => false, 'error' => 'unknown snapshot']);
        }
        $id = $want;
    } else {
        $id = end($ids);
    }
    $base = $root . '/' . BACKUP_DIR . '/' . $id;
    $restore = collect_rel_files($base . '/data');
    $remove  = collect_rel_files($base . '/created');
    if (!empty($_GET['dry'])) {
        respond(200, [
            'ok' => true, 'snapshot' => $id, 'dry' => true,
            'restore_count' => count($restore), 'remove_count' => count($remove),
            'restore' => $restore, 'remove' => $remove,
        ]);
    }
    $undoId = '';
    if (MAX_BACKUPS > 0 && empty($_GET['nosnap']) && (count($restore) + count($remove)) > 0) {
        $undoId = gmdate('Ymd-His') . '-rb' . bin2hex(random_bytes(4));
        if (snapshot_dir($root, $undoId, false) === false) {
            respond(500, ['ok' => false, 'error' => 'cannot snapshot the current state before rolling back (' . BACKUP_DIR . ' not writable, or disk full) — nothing changed']);
        }
    }
    $restored = 0;
    $failed = [];
    foreach ($restore as $rel) {
        $dst = safe_target($root, $rel);
        if ($dst === false || is_protected_target($dst, $root, $protectedLower, $selfReal, $cacheReal, $commitReal)) { $failed[] = $rel; continue; }
        $dir = dirname($dst);
        if (!is_dir($dir) && !@mkdir($dir, 0755, true)) { $failed[] = $rel; continue; }
        if (confined_dir($dir, $realRoot) === false || is_link($dst)) { $failed[] = $rel; continue; }
        if ($undoId !== '' && !backup_before_overwrite($root, $undoId, $rel, $dst, false)) { $failed[] = $rel; continue; }
        $tmp = $dst . TMP_SUFFIX;
        if (@copy($base . '/data/' . $rel, $tmp) && @rename($tmp, $dst)) {
            @chmod($dst, 0644);
            $restored++;
        } else {
            @unlink($tmp);
            $failed[] = $rel;
        }
    }
    $removed = 0;
    foreach ($remove as $rel) {
        $dst = safe_target($root, $rel);
        if ($dst === false || is_protected_target($dst, $root, $protectedLower, $selfReal, $cacheReal, $commitReal)) { $failed[] = $rel; continue; }
        if (confined_dir(dirname($dst), $realRoot) === false) { $failed[] = $rel; continue; }
        if (!is_file($dst) && !is_link($dst)) continue;
        $gone = false;
        if ($undoId !== '' && is_file($dst) && !is_link($dst)) {
            $bk = backup_move_delete($root, $undoId, $rel, $dst, false);
            if ($bk === 'fail') { $failed[] = $rel; continue; }
            $gone = ($bk === 'moved');
        }
        if (!$gone) $gone = @unlink($dst);
        if ($gone) {
            $removed++;
            prune_empty_dirs(dirname($dst), $root);
        } else {
            $failed[] = $rel;
        }
    }
    if ($undoId !== '' && $restored === 0 && $removed === 0) {
        rrmdir($root . '/' . BACKUP_DIR . '/' . $undoId);
        $undoId = '';
    }
    if ($failed) {
        state_write($root . '/' . COMMIT_FILE, '');
    } elseif (($restored + $removed) > 0 && is_file($base . '/commit.php')) {
        @copy($base . '/commit.php', $root . '/' . COMMIT_FILE);
    }
    if ($undoId !== '') prune_snapshots($root, [$id, $undoId]);
    if ($failed) {
        respond(500, [
            'ok' => false, 'error' => 'partial rollback', 'snapshot' => $id,
            'restored' => $restored, 'removed' => $removed,
            'failed' => $failed, 'undo' => $undoId,
        ]);
    }
    respond(200, ['ok' => true, 'snapshot' => $id, 'restored' => $restored, 'removed' => $removed, 'undo' => $undoId]);
}

respond(400, ['ok' => false, 'error' => 'unknown action']);
