<?php
/** Income and expense transactions (TXN-01, TXN-02, SEC-01). Balances are kept by the database trigger (DB-05). */
declare(strict_types=1);

/**
 * GET /api/transactions?month=2026-11&type=expense&category_id=3&account_id=1&search=rent
 * Paging (TXN-05): &limit=50 returns the newest 50; for the next page add &before_date=2026-11-05&before_id=123
 * (the date and id of the last row you have). This "keyset" paging stays fast on large tables, unlike OFFSET.
 * Without limit, up to 500 rows are returned (the dashboard and CSV use this). limit can be 1 - 5000.
 */
function transactions_list(array $user): void
{
    $where = ['a.user_id = ?'];
    $params = [$user['id']];
    $filters = [
        'month' => ["DATE_TRUNC('month', t.txn_date) = DATE_TRUNC('month', CAST(? AS date))", fn ($v) => "$v-01"],
        'type' => ['c.type = ?', null],
        'category_id' => ['t.category_id = ?', null],
        'account_id' => ['t.account_id = ?', null],
        'search' => ['t.description ILIKE ?', fn ($v) => "%$v%"],
    ];
    $beforeDate = query_param('before_date');
    $beforeId = query_param('before_id');
    if ($beforeDate !== null && $beforeId !== null) {
        $where[] = '(t.txn_date, t.transaction_id) < (CAST(? AS date), CAST(? AS int))';
        array_push($params, $beforeDate, $beforeId);
    }
    $limit = max(1, min(5000, (int) (query_param('limit') ?? 500)));
    foreach ($filters as $key => [$sql, $transform]) {
        $value = query_param($key);
        if ($value !== null) {
            $where[] = $sql;
            $params[] = $transform ? $transform($value) : $value;
        }
    }
    json_response(query(
        'SELECT t.*, a.account_name, c.name AS category, c.type
         FROM transactions t
         JOIN accounts a   ON a.account_id = t.account_id
         JOIN categories c ON c.category_id = t.category_id
         WHERE ' . implode(' AND ', $where) . '
         ORDER BY t.txn_date DESC, t.transaction_id DESC
         LIMIT ' . $limit, $params));
}

/** Both the account and the category must belong to the logged-in user (SEC-01). */
function require_own_account_and_category(int $userId, mixed $accountId, mixed $categoryId): void
{
    $row = query_one(
        'SELECT EXISTS (SELECT 1 FROM accounts   WHERE account_id  = ? AND user_id = ?)
            AND EXISTS (SELECT 1 FROM categories WHERE category_id = ? AND user_id = ?) AS ok',
        [$accountId, $userId, $categoryId, $userId]);
    if (!$row['ok']) {
        throw new ApiError(404, 'Account or category not found.');
    }
}

/** POST /api/transactions  { account_id, category_id, amount, txn_date, description } */
function transactions_create(array $user): void
{
    $body = request_body();
    require_own_account_and_category($user['id'], field($body, 'account_id'), field($body, 'category_id'));
    $rows = as_user($user['id'],
        'INSERT INTO transactions (account_id, category_id, amount, txn_date, description)
         VALUES (?, ?, ?, COALESCE(CAST(? AS date), CURRENT_DATE), ?) RETURNING *',
        [field($body, 'account_id'), field($body, 'category_id'), field($body, 'amount'), field($body, 'txn_date'), field($body, 'description')]);
    json_response($rows[0], 201);
}

/** PUT /api/transactions/{id} */
function transactions_update(array $user, int $id): void
{
    $body = request_body();
    require_own_account_and_category($user['id'], field($body, 'account_id'), field($body, 'category_id'));
    $rows = as_user($user['id'],
        'UPDATE transactions t
         SET account_id = ?, category_id = ?, amount = ?, txn_date = ?, description = ?
         FROM accounts a
         WHERE t.transaction_id = ? AND a.account_id = t.account_id AND a.user_id = ?
         RETURNING t.*',
        [field($body, 'account_id'), field($body, 'category_id'), field($body, 'amount'), field($body, 'txn_date'),
         field($body, 'description'), $id, $user['id']]);
    if (!$rows) {
        throw new ApiError(404, 'Transaction not found.');
    }
    json_response($rows[0]);
}

/** DELETE /api/transactions/{id} */
function transactions_delete(array $user, int $id): void
{
    $count = execute_as_user($user['id'],
        'DELETE FROM transactions t USING accounts a
         WHERE t.transaction_id = ? AND a.account_id = t.account_id AND a.user_id = ?', [$id, $user['id']]);
    if ($count === 0) {
        throw new ApiError(404, 'Transaction not found.');
    }
    no_content();
}
