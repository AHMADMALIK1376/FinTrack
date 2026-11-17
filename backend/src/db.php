<?php
/**
 * Database access through PDO (PHP's built-in database connector), always with
 * prepared statements, so user input is never mixed into the SQL (SEC-02).
 */
declare(strict_types=1);

/** The shared PDO connection to PostgreSQL, created on first use. */
function db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $host = env('PGHOST', 'localhost');
        // a path means a Unix socket folder (Linux/Mac); PDO wants it as host too
        $dsn = sprintf('pgsql:host=%s;port=%s;dbname=%s', $host, env('PGPORT', '5432'), env('PGDATABASE', 'fintrack'));
        $pdo = new PDO($dsn, env('PGUSER'), env('PGPASSWORD'), [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    }
    return $pdo;
}

/** Runs one statement with ? placeholders and returns all rows. */
function query(string $sql, array $params = []): array
{
    $statement = db()->prepare($sql);
    $statement->execute($params);
    return $statement->columnCount() > 0 ? $statement->fetchAll() : [];
}

/** Runs one statement and returns the first row, or null. */
function query_one(string $sql, array $params = []): ?array
{
    return query($sql, $params)[0] ?? null;
}

/** Runs one statement and returns how many rows it changed. */
function execute(string $sql, array $params = []): int
{
    $statement = db()->prepare($sql);
    $statement->execute($params);
    return $statement->rowCount();
}

/**
 * Runs $work inside one database transaction (all or nothing). When $userId is given,
 * app.user_id is set first, so the audit trigger records who made the change (DB-09).
 * @return mixed whatever $work returns
 * @throws Throwable the original error, after rolling back
 */
function in_transaction(?int $userId, callable $work): mixed
{
    $pdo = db();
    $pdo->beginTransaction();
    try {
        if ($userId !== null) {
            query("SELECT set_config('app.user_id', ?, true)", [(string) $userId]);
        }
        $result = $work();
        $pdo->commit();
        return $result;
    }
    catch (Throwable $error) {
        $pdo->rollBack();
        throw $error;
    }
}

/** Runs one change as the logged-in user (DB-09) and returns its rows (with RETURNING) or []. */
function as_user(int $userId, string $sql, array $params = []): array
{
    return in_transaction($userId, fn () => query($sql, $params));
}

/** Like as_user(), but returns the number of rows changed. */
function execute_as_user(int $userId, string $sql, array $params = []): int
{
    return in_transaction($userId, fn () => execute($sql, $params));
}
