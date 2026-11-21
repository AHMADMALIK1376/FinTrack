<?php
/**
 * Installs the FinTrack database on a server (Neon, Render or any PostgreSQL) in one command,
 * without psql:
 *
 *   php bin/install-db.php "postgresql://owner:password@host/dbname?sslmode=require" [--with-demo] [--reset]
 *
 *   --with-demo  also load the sample committees and SMS (database/demo/) for the demo user
 *   --reset      allow installing over an existing FinTrack database. This deletes all its data.
 *
 * It runs database/01_*.sql ... in order as the owner, gives the website's account
 * (fintrack_app) a new random password instead of the local one in 06_roles.sql, and prints
 * the DATABASE_URL to give the website. Run it from your own computer; the password is
 * shown only here.
 */
declare(strict_types=1);

$args = array_slice($argv, 1);
$url = null;
$withDemo = false;
$reset = false;
foreach ($args as $arg) {
    if ($arg === '--with-demo') {
        $withDemo = true;
    } elseif ($arg === '--reset') {
        $reset = true;
    } elseif ($url === null && !str_starts_with($arg, '--')) {
        $url = $arg;
    } else {
        fwrite(STDERR, "Unknown option: $arg\n");
        exit(2);
    }
}
if ($url === null) {
    fwrite(STDERR, "Usage: php bin/install-db.php \"postgresql://owner:password@host/dbname?sslmode=require\" [--with-demo] [--reset]\n"
        . "Use the owner's connection string from your database host (on Neon: Dashboard > Connect).\n");
    exit(2);
}
if (!extension_loaded('pdo_pgsql')) {
    fwrite(STDERR, "PHP's pdo_pgsql extension is off. In php.ini, remove the ; before extension=pdo_pgsql.\n");
    exit(1);
}

$p = parse_url($url);
if ($p === false || !in_array($p['scheme'] ?? '', ['postgres', 'postgresql'], true) || !isset($p['host'], $p['user'])) {
    fwrite(STDERR, "That doesn't look like a PostgreSQL connection string (postgresql://user:password@host/dbname).\n");
    exit(2);
}
parse_str($p['query'] ?? '', $query);
$host = urldecode($p['host']);
$port = (string) ($p['port'] ?? 5432);
$dbname = urldecode(ltrim($p['path'] ?? '/postgres', '/'));
$sslmode = is_string($query['sslmode'] ?? null) ? $query['sslmode'] : null;
$dsn = "pgsql:host=$host;port=$port;dbname=$dbname" . ($sslmode ? ";sslmode=$sslmode" : '');

try {
    $pdo = new PDO($dsn, urldecode($p['user']), isset($p['pass']) ? urldecode($p['pass']) : null,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
} catch (PDOException $e) {
    fwrite(STDERR, "Couldn't connect: " . $e->getMessage() . "\n");
    exit(1);
}
$pdo->exec('SET client_min_messages = warning');

$exists = $pdo->query("SELECT to_regclass('public.users') IS NOT NULL")->fetchColumn();
if ($exists && !$reset) {
    fwrite(STDERR, "This database already has FinTrack tables. Installing again would delete all their data.\n"
        . "If that's what you want, add --reset.\n");
    exit(1);
}

$root = dirname(__DIR__, 2) . '/database';
$files = glob("$root/[0-9][0-9]_*.sql");
sort($files);
if ($withDemo) {
    $files[] = "$root/demo/committees_demo.sql";
    $files[] = "$root/demo/sms_demo.sql";
}

// a strong password for the website's account; the local one in 06_roles.sql is public on GitHub
$appPassword = rtrim(strtr(base64_encode(random_bytes(24)), '+/', 'Ab'), '=');

echo "Installing FinTrack into \"$dbname\" on $host\n";
foreach ($files as $file) {
    $sql = file_get_contents($file);
    if (basename($file) === '06_roles.sql') {
        $sql = str_replace("PASSWORD 'fintrack_app_local'", "PASSWORD '$appPassword'", $sql, $count);
        if ($count !== 1) {
            fwrite(STDERR, "06_roles.sql has changed: couldn't set the website's password. Nothing after 05 was run.\n");
            exit(1);
        }
    }
    try {
        $pdo->exec($sql);
    } catch (PDOException $e) {
        fwrite(STDERR, "  failed in " . basename($file) . ": " . $e->getMessage() . "\n");
        exit(1);
    }
    echo '  ok  ' . str_replace(dirname($root) . '/', '', $file) . "\n";
}

$appUrl = sprintf('postgresql://fintrack_app:%s@%s%s/%s%s', rawurlencode($appPassword), $host,
    isset($p['port']) ? ':' . $p['port'] : '', rawurlencode($dbname), $sslmode ? "?sslmode=$sslmode" : '');
echo "\nDone. Give the website this DATABASE_URL (on Render: Environment > DATABASE_URL).\n"
   . "It logs in as fintrack_app, which can't change the tables. Keep it private, like a password:\n\n"
   . "  $appUrl\n\n"
   . "Demo log-in: demo@fintrack.pk / demo1234" . ($withDemo ? ' (with sample committees and SMS)' : '') . "\n";
