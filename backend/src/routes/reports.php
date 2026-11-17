<?php
/** The dashboard's numbers (RPT-01, BUD-03), from the report views and check_budget(). */
declare(strict_types=1);

/** GET /api/reports/dashboard?month=2026-11 */
function reports_dashboard(array $user): void
{
    $month = (query_param('month') ?? this_month()) . '-01';
    $uid = $user['id'];
    $balance = query_one('SELECT COALESCE(SUM(balance), 0) AS total FROM accounts WHERE user_id = ?', [$uid]);
    $summary = query_one('SELECT * FROM monthly_summary WHERE user_id = ? AND month = CAST(? AS date)', [$uid, $month])
        ?? ['total_income' => 0, 'total_expense' => 0, 'net_saving' => 0];
    json_response([
        'total_balance' => $balance['total'],
        'total_income' => $summary['total_income'],
        'total_expense' => $summary['total_expense'],
        'net_saving' => $summary['net_saving'],
        'by_category' => query(
            'SELECT category, total_spent FROM category_spending
             WHERE user_id = ? AND month = CAST(? AS date) ORDER BY total_spent DESC', [$uid, $month]),
        'trend' => query(
            "SELECT TO_CHAR(month, 'Mon YYYY') AS label, total_income, total_expense
             FROM monthly_summary WHERE user_id = ? AND month > (CAST(? AS date) - INTERVAL '6 months')
             AND month <= CAST(? AS date) ORDER BY month", [$uid, $month, $month]),
        'budget_warnings' => query('SELECT * FROM check_budget(?, CAST(? AS date))', [$uid, $month]),
    ]);
}
