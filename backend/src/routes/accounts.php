<?php
/** Accounts and transfers (ACC-01, ACC-04). Changes are made as the logged-in user (DB-09). */
declare(strict_types=1);

/** GET /api/accounts */
function accounts_list(array $user): void
{
    json_response(query('SELECT * FROM accounts WHERE user_id = ? ORDER BY account_id', [$user['id']]));
}

/** POST /api/accounts  { account_name, account_type } */
function accounts_create(array $user): void
{
    $body = request_body();
    $rows = as_user($user['id'],
        'INSERT INTO accounts (user_id, account_name, account_type) VALUES (?, ?, ?) RETURNING *',
        [$user['id'], field($body, 'account_name'), field($body, 'account_type')]);
    json_response($rows[0], 201);
}

/** PUT /api/accounts/{id}  { account_name, account_type } */
function accounts_update(array $user, int $id): void
{
    $body = request_body();
    $rows = as_user($user['id'],
        'UPDATE accounts SET account_name = ?, account_type = ? WHERE account_id = ? AND user_id = ? RETURNING *',
        [field($body, 'account_name'), field($body, 'account_type'), $id, $user['id']]);
    if (!$rows) {
        throw new ApiError(404, 'Account not found.');
    }
    json_response($rows[0]);
}

/** DELETE /api/accounts/{id} (its transactions go too) */
function accounts_delete(array $user, int $id): void
{
    if (execute_as_user($user['id'], 'DELETE FROM accounts WHERE account_id = ? AND user_id = ?', [$id, $user['id']]) === 0) {
        throw new ApiError(404, 'Account not found.');
    }
    no_content();
}

/** POST /api/accounts/transfer  { from_account, to_account, amount }: one atomic unit (transfer_money procedure) */
function accounts_transfer(array $user): void
{
    $body = request_body();
    $from = field($body, 'from_account');
    $to = field($body, 'to_account');
    $own = query_one('SELECT COUNT(*)::int AS n FROM accounts WHERE user_id = ? AND account_id IN (?, ?)', [$user['id'], $from, $to]);
    if ((int) $own['n'] !== 2) {
        throw new ApiError(404, 'Account not found.');
    }
    in_transaction($user['id'], fn () => query('CALL transfer_money(?, ?, ?)', [$from, $to, field($body, 'amount')]));
    json_response(['ok' => true]);
}
