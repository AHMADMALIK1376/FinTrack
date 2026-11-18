<?php
/**
 * Recurring transactions (TXN-07): rules that post a transaction every week or month.
 * The posting itself is done by the database function post_due_recurring() (database/09_recurring.sql).
 */
declare(strict_types=1);

const RECURRING_SELECT = 'SELECT r.*, a.account_name, c.name AS category, c.type
    FROM recurring_transactions r
    JOIN accounts a   ON a.account_id = r.account_id
    JOIN categories c ON c.category_id = r.category_id';

/** Posts this user's due rules (as the user, so the audit log records them). Returns how many were added. */
function post_due_for(int $userId): int
{
    return (int) as_user($userId, 'SELECT post_due_recurring(?) AS posted', [$userId])[0]['posted'];
}

/** GET /api/recurring */
function recurring_list(array $user): void
{
    json_response(query(RECURRING_SELECT . ' WHERE r.user_id = ? ORDER BY r.is_active DESC, r.next_run_date, r.recurring_id', [$user['id']]));
}

/**
 * POST /api/recurring  { account_id, category_id, amount, description, frequency: weekly|monthly, start_date }
 * If the start date is today or earlier, the due transactions are posted straight away.
 */
function recurring_create(array $user): void
{
    $body = request_body();
    $start = (string) (field($body, 'start_date') ?? date('Y-m-d'));
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $start)) {
        throw new ApiError(400, 'Choose a start date.');
    }
    $range = query_one("SELECT CAST(? AS date) < CURRENT_DATE - INTERVAL '1 year' AS too_early,
                               CAST(? AS date) > CURRENT_DATE + INTERVAL '1 year' AS too_late", [$start, $start]);
    if ($range['too_early'] || $range['too_late']) {
        throw new ApiError(400, 'The start date must be within a year of today.');
    }
    require_own_account_and_category($user['id'], field($body, 'account_id'), field($body, 'category_id'));
    $rule = as_user($user['id'],
        'INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, description, frequency, start_date, next_run_date)
         VALUES (?, ?, ?, ?, ?, ?, CAST(? AS date), CAST(? AS date)) RETURNING recurring_id',
        [$user['id'], field($body, 'account_id'), field($body, 'category_id'), field($body, 'amount'),
         field($body, 'description'), field($body, 'frequency'), $start, $start])[0];
    $posted = post_due_for($user['id']);
    json_response(['rule' => query_one(RECURRING_SELECT . ' WHERE r.recurring_id = ?', [$rule['recurring_id']]), 'posted' => $posted], 201);
}

/**
 * PUT /api/recurring/{id}  { is_active?, amount?, description? }
 * Resuming a paused rule skips the dates that passed while it was paused (they are not posted).
 */
function recurring_update(array $user, int $id): void
{
    $body = request_body();
    $rule = query_one('SELECT * FROM recurring_transactions WHERE recurring_id = ? AND user_id = ?', [$id, $user['id']]);
    if ($rule === null) {
        throw new ApiError(404, 'Recurring transaction not found.');
    }
    $active = array_key_exists('is_active', $body) ? (bool) $body['is_active'] : (bool) $rule['is_active'];
    $amount = field($body, 'amount') ?? $rule['amount'];
    $description = array_key_exists('description', $body) ? field($body, 'description') : $rule['description'];
    in_transaction($user['id'], function () use ($id, $active, $amount, $description, $rule) {
        query('UPDATE recurring_transactions SET is_active = ?, amount = ?, description = ? WHERE recurring_id = ?',
            [$active ? 'true' : 'false', $amount, $description, $id]);
        if ($active && !$rule['is_active']) {
            // move to the first date that is today or later, without posting the missed ones
            query("UPDATE recurring_transactions r SET (times_posted, next_run_date) = (
                       SELECT n, recurring_date(r.start_date, r.frequency, n)
                       FROM generate_series(r.times_posted, r.times_posted + 600) n
                       WHERE recurring_date(r.start_date, r.frequency, n) >= CURRENT_DATE
                       ORDER BY n LIMIT 1)
                   WHERE recurring_id = ?", [$id]);
        }
    });
    $posted = $active ? post_due_for($user['id']) : 0;
    json_response(['rule' => query_one(RECURRING_SELECT . ' WHERE r.recurring_id = ?', [$id]), 'posted' => $posted]);
}

/** DELETE /api/recurring/{id}  (transactions it already posted are kept) */
function recurring_delete(array $user, int $id): void
{
    if (execute('DELETE FROM recurring_transactions WHERE recurring_id = ? AND user_id = ?', [$id, $user['id']]) === 0) {
        throw new ApiError(404, 'Recurring transaction not found.');
    }
    no_content();
}
