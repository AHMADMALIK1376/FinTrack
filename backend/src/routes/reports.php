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

/** Groups of fewer people than this are not shown in the FinTrack averages (privacy). */
const MIN_USERS_FOR_AVERAGE = 5;

/**
 * GET /api/reports/year?year=2026  (RPT-02, DB-12)
 * The user's year by month and by category (live: about 0.2 ms with the indexes), and the
 * FinTrack-wide average per category from the materialized view report_monthly_averages,
 * which is rebuilt at most once a day. Transfers between the user's own accounts are left out.
 */
function reports_year(array $user): void
{
    $year = (int) (query_param('year') ?? date('Y'));
    if ($year < 2000 || $year > 2100) {
        throw new ApiError(400, 'Choose a year between 2000 and 2100.');
    }
    $from = "$year-01-01";
    $to = ($year + 1) . '-01-01';
    $uid = $user['id'];

    $years = array_map(fn ($r) => (int) $r['year'], query(
        "SELECT DISTINCT EXTRACT(YEAR FROM t.txn_date)::int AS year
         FROM transactions t JOIN accounts a ON a.account_id = t.account_id
         WHERE a.user_id = ? ORDER BY year DESC", [$uid]));

    // one row per category and month that had money in it
    $cells = query(
        "SELECT c.category_id, c.name AS category, c.type, EXTRACT(MONTH FROM t.txn_date)::int AS month,
                SUM(t.amount) AS total, COUNT(*)::int AS entries
         FROM transactions t
         JOIN categories c ON c.category_id = t.category_id
         WHERE c.user_id = ? AND c.name <> 'Transfer'
           AND t.txn_date >= CAST(? AS date) AND t.txn_date < CAST(? AS date)
         GROUP BY c.category_id, c.name, c.type, month
         ORDER BY c.type DESC, c.name, month", [$uid, $from, $to]);

    $refreshedAt = query_one("SELECT refresh_reports(INTERVAL '1 day') AS at")['at'];
    $averages = query(
        'SELECT category, type, ROUND(AVG(average_per_user), 2) AS average_per_month, MIN(users)::int AS fewest_users
         FROM report_monthly_averages
         WHERE month >= CAST(? AS date) AND month < CAST(? AS date)
         GROUP BY category, type
         HAVING MIN(users) >= ?', [$from, $to, MIN_USERS_FOR_AVERAGE]);

    json_response([
        'year' => $year,
        'years' => $years ?: [(int) date('Y')],
        'cells' => $cells,
        'averages' => $averages,
        'averages_updated_at' => $refreshedAt,
        'min_users_for_average' => MIN_USERS_FOR_AVERAGE,
    ]);
}
