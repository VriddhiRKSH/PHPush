<?php

const DEPLOY_TOKEN = '__PASTE_64_HEX_TOKEN_HERE__';
const ALLOW_IPS = [];
const MAX_PUSH_BYTES = 0;

const CACHE_FILE = '.phpush-cache.php';
const COMMIT_FILE = '.phpush-commit.php';
const TMP_SUFFIX = '.phpush-tmp';
const STATE_GUARD = "<?php http_response_code(404); exit; ?>\n";

$root = rtrim(str_replace('\\', '/', __DIR__), '/');
$realRoot = realpath($root);
$realRoot = $realRoot === false ? $root : str_replace('\\', '/', $realRoot);

$self = basename(__FILE__);
$protectedLower = array_map('strtolower', [$self, CACHE_FILE, COMMIT_FILE]);

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
    header('X-Content-Type-Options: nosniff');
    header('X-Robots-Tag: noindex, nofollow');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function respond_text($code, $body) {
    http_response_code($code);
    header('Content-Type: text/plain; charset=utf-8');
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
    return $root . '/' . implode('/', $parts);
}

function is_reserved_name($name) {
    $bn = rtrim(strtolower(basename($name)), " .");
    if ($bn === '') return false;
    if (strlen($bn) >= strlen(TMP_SUFFIX) && substr($bn, -strlen(TMP_SUFFIX)) === TMP_SUFFIX) return true;
    return false;
}

function is_protected_target($target, array $protectedLower, $selfReal, $cacheReal, $commitReal) {
    $bn = rtrim(strtolower(basename($target)), " .");
    if (in_array($bn, $protectedLower, true)) return true;
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
        if ($rel !== '') $out[] = $rel;
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

$action = $_GET['action'] ?? '';

if ($action === 'manifest') {
    $cachePath = $root . '/' . CACHE_FILE;
    $cache = [];
    if (empty($_GET['fresh'])) {
        $decoded = json_decode(state_read($cachePath), true);
        if (is_array($decoded)) $cache = $decoded;
    }
    $newCache = [];
    $lines = [];
    foreach (list_files($root) as $rel) {
        $bn = strtolower(basename($rel));
        if (in_array($bn, $protectedLower, true) || is_reserved_name($rel)) continue;
        $full = $root . '/' . $rel;
        $size = @filesize($full);
        $mtime = @filemtime($full);
        $key = $size . ':' . $mtime;
        if (isset($cache[$rel]['k'], $cache[$rel]['h']) && $cache[$rel]['k'] === $key) {
            $hash = $cache[$rel]['h'];
        } else {
            $hash = sha1_file($full);
            if ($hash === false) continue;
        }
        $newCache[$rel] = ['k' => $key, 'h' => $hash];
        $lines[] = $hash . "\t" . $rel;
    }
    $enc = json_encode($newCache, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if ($enc !== false) state_write($cachePath, $enc);
    respond_text(200, $lines ? implode("\n", $lines) . "\n" : '');
}

if ($action === 'push') {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        respond(405, ['ok' => false, 'error' => 'method not allowed']);
    }
    $rel = b64url_decode($_SERVER['HTTP_X_DEPLOY_PATH'] ?? '');
    $target = safe_target($root, $rel);
    if ($target === false || is_protected_target($target, $protectedLower, $selfReal, $cacheReal, $commitReal)) {
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
        if (!@rename($tmp, $target)) {
            @unlink($tmp);
            respond(500, ['ok' => false, 'error' => 'finalize failed']);
        }
        @chmod($target, 0644);
        respond(200, ['ok' => true, 'path' => $rel, 'bytes' => $bytes, 'sha1' => sha1_file($target)]);
    }
    respond(200, ['ok' => true, 'path' => $rel, 'bytes' => $bytes, 'partial' => true]);
}

if ($action === 'delete') {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        respond(405, ['ok' => false, 'error' => 'method not allowed']);
    }
    $list = json_decode(file_get_contents('php://input'), true);
    $deleted = [];
    $errors = [];
    if (is_array($list)) {
        foreach ($list as $rel) {
            $target = safe_target($root, $rel);
            if ($target === false || is_protected_target($target, $protectedLower, $selfReal, $cacheReal, $commitReal)) {
                $errors[] = 'bad delete: ' . (is_string($rel) ? $rel : 'non-string');
                continue;
            }
            if (confined_dir(dirname($target), $realRoot) === false) {
                $errors[] = 'bad delete: ' . (is_string($rel) ? $rel : 'non-string');
                continue;
            }
            if ((is_file($target) || is_link($target)) && @unlink($target)) {
                $deleted[] = $rel;
                prune_empty_dirs(dirname($target), $root);
            }
        }
    }
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

respond(400, ['ok' => false, 'error' => 'unknown action']);
