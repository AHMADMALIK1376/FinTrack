<?php
/** Monthly budgets per expense category (BUD-01, BUD-03). */
declare(strict_types=1);

/** GET /api/budgets?month=2026-11  -> budgets with the amount spent so far */
function budgets_list(array $user): void
{
    $month = (query_param('month') ?? this_month()) . '-01';
    // spending per budget for that month only (a date range, so the category + date index is used; see docs/performance.md)
    json_response(query(
        "SELECT b.*, c.name AS category, s.spent
         FROM budgets b
         JOIN categories c ON c.category_id = b.category_id
         CROSS JOIN LATERAL (
             SELECT COALESCE(SUM(t.amount), 0) AS spent FROM transactions t
             WHERE t.category_id = b.category_id AND t.txn_date >= b.month AND t.txn_date < b.month + INTERVAL '1 month'
         ) s
         WHERE b.user_id = ? AND b.month = CAST(? AS date)
         ORDER BY c.name", [$user['id'], $month]));
}

/** POST /api/budgets  { category_id, limit_amount, month: "2026-11" } (sets or changes the limit) */
function budgets_save(array $user): void
{
    $body = request_body();
    $month = (string) field($body, 'month');
    if (!preg_match('/^\d{4}-(0[1-9]|1[0-2])$/', $month)) {
        throw new ApiError(400, 'Choose a month for this budget.');
    }
    // SEC-01, BUD-01: only the user's own expense categories can have a budget
    $category = query_one('SELECT type FROM categories WHERE category_id = ? AND user_id = ?', [field($body, 'category_id'), $user['id']]);
    if ($category === null) {
        throw new ApiError(404, 'Category not found.');
    }
    if ($category['type'] !== 'expense') {
        throw new ApiError(400, 'Budgets can only be set for expense categories.');
    }
    $rows = as_user($user['id'],
        'INSERT INTO budgets (user_id, category_id, limit_amount, month)
         VALUES (?, ?, ?, CAST(? AS date))
         ON CONFLICT (user_id, category_id, month) DO UPDATE SET limit_amount = EXCLUDED.limit_amount
         RETURNING *', [$user['id'], field($body, 'category_id'), field($body, 'limit_amount'), "$month-01"]);
    json_response($rows[0], 201);
}

/** DELETE /api/budgets/{id} */
function budgets_delete(array $user, int $id): void
{
    if (execute_as_user($user['id'], 'DELETE FROM budgets WHERE budget_id = ? AND user_id = ?', [$id, $user['id']]) === 0) {
        throw new ApiError(404, 'Budget not found.');
    }
    no_content();
}
