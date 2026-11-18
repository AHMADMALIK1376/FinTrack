<?php
/**
 * Small helpers for answering HTTP requests with JSON, and the error type used
 * for answers like 404 "Account not found." (UI-03: plain sentences).
 */
declare(strict_types=1);

/** An error that becomes an HTTP answer with a plain message. */
final class ApiError extends Exception
{
    public function __construct(public readonly int $status, string $message)
    {
        parent::__construct($message);
    }
}

/** Sends $data as JSON with the given status code. */
function json_response(mixed $data, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

/** Sends an empty 204 answer (used after deleting). */
function no_content(): void
{
    http_response_code(204);
}

/** The request's JSON body as an array. Broken JSON is a 400. */
function request_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || trim($raw) === '') {
        return [];
    }
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        throw new ApiError(400, 'The request could not be read. Please try again.');
    }
    return $data;
}

/** The query string value $key, or null. */
function query_param(string $key): ?string
{
    $value = $_GET[$key] ?? null;
    return is_string($value) && $value !== '' ? $value : null;
}

/** The current month as YYYY-MM. */
function this_month(): string
{
    return gmdate('Y-m');
}

/**
 * One value from the request body: a string or number, or null when missing.
 * Lists and objects are refused with a plain 400, so they never reach the SQL.
 */
function field(array $body, string $key): string|int|float|bool|null
{
    $value = $body[$key] ?? null;
    if (is_array($value)) {
        throw new ApiError(400, 'A value has the wrong format.');
    }
    return $value === '' ? null : $value;
}
