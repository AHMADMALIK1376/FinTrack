<?php
/**
 * Settings: reads backend/.env into the environment (values already set in the
 * real environment win, so CI and tests can override them), and checks that the
 * database password is there, with plain instructions when it is not.
 */
declare(strict_types=1);

/** Loads KEY=value lines from a .env file. Lines starting with # are comments. */
function load_env(string $file): void
{
    if (!is_file($file)) {
        return;
    }
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
            continue;
        }
        [$key, $value] = array_map('trim', explode('=', $line, 2));
        $value = trim($value, "\"'");
        if (getenv($key) === false) {
            putenv("$key=$value");
            $_ENV[$key] = $value;
        }
    }
}

/** Returns a setting from the environment, or $default. */
function env(string $key, ?string $default = null): ?string
{
    $value = getenv($key);
    return $value === false ? $default : $value;
}

/**
 * Explains what is wrong when the database password is missing (UI-03):
 * no .env, Notepad's .env.txt, or a .env without PGPASSWORD. Returns null when all is well.
 */
function database_settings_problem(): ?string
{
    if (env('PGPASSWORD') !== null) {
        return null;
    }
    $dir = dirname(__DIR__);
    if (!is_file("$dir/.env") && is_file("$dir/.env.txt")) {
        $hint = 'Found backend/.env.txt: Windows saved it with the wrong name. Rename it to .env (PowerShell: Rename-Item .env.txt .env).';
    }
    elseif (!is_file("$dir/.env")) {
        $hint = 'There is no backend/.env file. Copy backend/.env.example to backend/.env and fill in your settings.';
    }
    else {
        $hint = 'backend/.env has no PGPASSWORD line. Add PGPASSWORD=<your password> (no # in front).';
    }
    return "Database password not set. $hint";
}

/**
 * Hosting (Neon, Render ...) gives the database as one line:
 *   DATABASE_URL=postgresql://user:password@host:5432/dbname?sslmode=require
 * This fills in PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD and PGSSLMODE from it,
 * unless they are already set one by one.
 */
function apply_database_url(?string $url): void
{
    if ($url === null || $url === '') {
        return;
    }
    $parts = parse_url($url);
    if ($parts === false || !in_array($parts['scheme'] ?? '', ['postgres', 'postgresql'], true)) {
        return;
    }
    parse_str($parts['query'] ?? '', $query);
    $values = [
        'PGHOST' => isset($parts['host']) ? urldecode($parts['host']) : null,
        'PGPORT' => isset($parts['port']) ? (string) $parts['port'] : null,
        'PGDATABASE' => isset($parts['path']) ? urldecode(ltrim($parts['path'], '/')) : null,
        'PGUSER' => isset($parts['user']) ? urldecode($parts['user']) : null,
        'PGPASSWORD' => isset($parts['pass']) ? urldecode($parts['pass']) : null,
        'PGSSLMODE' => isset($query['sslmode']) && is_string($query['sslmode']) ? $query['sslmode'] : null,
    ];
    foreach ($values as $key => $value) {
        if ($value !== null && $value !== '' && getenv($key) === false) {
            putenv("$key=$value");
        }
    }
}

load_env(dirname(__DIR__) . '/.env');
apply_database_url(env('DATABASE_URL'));
