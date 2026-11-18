<?php
/**
 * FinTrack REST API in PHP: matches the request to a route, checks the log-in
 * token where needed (AUTH-04), and turns every error into a plain JSON message (UI-03).
 * Every route works only on the logged-in user's own rows (SEC-01).
 */
declare(strict_types=1);

require_once __DIR__ . '/env.php';
require_once __DIR__ . '/db.php';
require_once __DIR__ . '/jwt.php';
require_once __DIR__ . '/http.php';
foreach (glob(__DIR__ . '/routes/*.php') as $file) {
    require_once $file;
}

/**
 * The route table: [method, path pattern, handler, needs log-in].
 * {id} in a pattern matches a number and is passed to the handler.
 */
function routes(): array
{
    return [
        ['GET', '/api/health', 'health', false],
        ['POST', '/api/auth/register', 'auth_register', false],
        ['POST', '/api/auth/login', 'auth_login', false],
        ['GET', '/api/accounts', 'accounts_list', true],
        ['POST', '/api/accounts', 'accounts_create', true],
        ['POST', '/api/accounts/transfer', 'accounts_transfer', true],
        ['PUT', '/api/accounts/{id}', 'accounts_update', true],
        ['DELETE', '/api/accounts/{id}', 'accounts_delete', true],
        ['GET', '/api/categories', 'categories_list', true],
        ['POST', '/api/categories', 'categories_create', true],
        ['PUT', '/api/categories/{id}', 'categories_update', true],
        ['DELETE', '/api/categories/{id}', 'categories_delete', true],
        ['GET', '/api/recurring', 'recurring_list', true],
        ['POST', '/api/recurring', 'recurring_create', true],
        ['PUT', '/api/recurring/{id}', 'recurring_update', true],
        ['DELETE', '/api/recurring/{id}', 'recurring_delete', true],
        ['GET', '/api/transactions', 'transactions_list', true],
        ['POST', '/api/transactions', 'transactions_create', true],
        ['PUT', '/api/transactions/{id}', 'transactions_update', true],
        ['DELETE', '/api/transactions/{id}', 'transactions_delete', true],
        ['GET', '/api/budgets', 'budgets_list', true],
        ['POST', '/api/budgets', 'budgets_save', true],
        ['DELETE', '/api/budgets/{id}', 'budgets_delete', true],
        ['GET', '/api/goals', 'goals_list', true],
        ['POST', '/api/goals', 'goals_create', true],
        ['PATCH', '/api/goals/{id}/add', 'goals_add', true],
        ['DELETE', '/api/goals/{id}', 'goals_delete', true],
        ['GET', '/api/reports/dashboard', 'reports_dashboard', true],
        ['GET', '/api/reports/year', 'reports_year', true],
        ['GET', '/api/activity', 'activity_list', true],
    ];
}

/** Answers one API request. */
function handle_request(string $method, string $path): void
{
    try {
        $problem = database_settings_problem();
        if ($problem !== null) {
            throw new ApiError(500, $problem);
        }
        foreach (routes() as [$routeMethod, $pattern, $handler, $needsLogin]) {
            $regex = '#^' . str_replace('\{id\}', '(\d+)', preg_quote($pattern, '#')) . '$#';
            if ($routeMethod !== $method || !preg_match($regex, $path, $match)) {
                continue;
            }
            $args = array_map('intval', array_slice($match, 1));
            if ($needsLogin) {
                array_unshift($args, current_user());
            }
            $handler(...$args);
            return;
        }
        throw new ApiError(404, 'Not found.');
    }
    catch (Throwable $error) {
        send_error($error);
    }
}

/** The logged-in user from the Authorization header ({id, name, email}), or a 401. */
function current_user(): array
{
    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    $token = str_starts_with($header, 'Bearer ') ? substr($header, 7) : '';
    if ($token === '') {
        throw new ApiError(401, 'Please log in first.');
    }
    $user = jwt_verify($token);
    if ($user === null) {
        throw new ApiError(401, 'Your session has expired. Please log in again.');
    }
    return $user;
}

/** Turns an error into a plain JSON answer; unexpected errors are logged, never shown. */
function send_error(Throwable $error): void
{
    if ($error instanceof ApiError) {
        json_response(['error' => $error->getMessage()], $error->status);
        return;
    }
    if ($error instanceof PDOException) {
        $state = $error->errorInfo[0] ?? (string) $error->getCode();
        $known = [
            '23505' => 'This item already exists.',
            '23503' => 'This item is linked to other records and cannot be changed.',
            '23001' => 'This item is linked to other records and cannot be changed.', // ON DELETE RESTRICT on PostgreSQL 18
            '23514' => 'A value is not allowed (for example, amounts must be greater than zero).',
            '23502' => 'Please fill in all required fields.',
            '22P02' => 'A value has the wrong format.',
            '22007' => 'A date has the wrong format.',
            '22008' => 'That date does not exist.',
            '22003' => 'That number is too large.',
        ];
        if ($state === 'P0001') {
            // a message raised by our own triggers or procedures, e.g. "Not enough balance for this transfer"
            json_response(['error' => raised_message($error)], 400);
            return;
        }
        // the FinTrack types from database/07_types.sql (DB-11)
        $text = $error->getMessage();
        $typeMessages = [
            'account_kind' => 'Choose an account type: bank, cash, wallet or card.',
            'category_kind' => 'Choose whether the category is income or expense.',
            'money_pkr' => 'Amounts can be at most Rs 999,999,999.99.',
            'recurrence_kind' => 'Choose how often it repeats: weekly or monthly.',
        ];
        foreach ($typeMessages as $type => $message) {
            if (in_array($state, ['22P02', '23514'], true) && str_contains($text, $type)) {
                json_response(['error' => $message], 400);
                return;
            }
        }
        if (isset($known[$state])) {
            json_response(['error' => $known[$state]], 400);
            return;
        }
    }
    error_log('[FinTrack] ' . get_class($error) . ': ' . $error->getMessage());
    json_response(['error' => 'Something went wrong on the server.'], 500);
}

/** The text of a RAISE EXCEPTION, without PostgreSQL's "ERROR:" prefix and CONTEXT lines. */
function raised_message(PDOException $error): string
{
    $text = $error->errorInfo[2] ?? $error->getMessage();
    $first = strtok($text, "\n");
    return trim(preg_replace('/^.*?ERROR:\s*/', '', (string) $first));
}

/** GET /api/health: the server is up, and which database role it uses (DB-10). */
function health(): void
{
    $row = query_one('SELECT current_user AS role');
    json_response(['status' => 'ok', 'database_role' => $row['role']]);
}
