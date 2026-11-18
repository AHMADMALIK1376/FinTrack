-- =====================================================================
-- database/perf/explain.sql  -  the performance study (DB-07, DB-12)
--
-- Run on fintrack_perf after generate.sql. It times the queries the website
-- really runs, for one user (Perf User 250) and one month:
--
--   PART 1  without the indexes: they are dropped INSIDE a transaction that
--           is rolled back at the end, so nothing is really removed
--   PART 2  with the indexes
--   PART 3  check_budget(): the old query (through the category_spending
--           view) against the new one (a date range per budget)
--   PART 4  FinTrack-wide averages: live query against the materialized view
--
-- In pgAdmin, run it with "Execute script" (F5) and read each plan's last
-- line, "Execution Time". Our results are in docs/performance.md.
-- Times change a little between runs and computers; the size of the
-- difference is what matters.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PART 1: WITHOUT the indexes
-- ---------------------------------------------------------------------
BEGIN;
DROP INDEX idx_txn_account_date, idx_txn_category_date, idx_accounts_user, idx_categories_user;

-- Q1 Transactions page: newest 51 rows of one month (TXN-02, TXN-05)
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.*, a.account_name, c.name AS category, c.type
FROM transactions t JOIN accounts a ON a.account_id = t.account_id JOIN categories c ON c.category_id = t.category_id
WHERE a.user_id = 250 AND DATE_TRUNC('month', t.txn_date) = DATE '2026-10-01'
ORDER BY t.txn_date DESC, t.transaction_id DESC LIMIT 51;

-- Q2 Transactions page: search the description
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.*, a.account_name
FROM transactions t JOIN accounts a ON a.account_id = t.account_id
WHERE a.user_id = 250 AND t.description ILIKE '%imtiaz%'
ORDER BY t.txn_date DESC, t.transaction_id DESC LIMIT 51;

-- Q3 Dashboard: the month's income and expense (monthly_summary view, RPT-01)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM monthly_summary WHERE user_id = 250 AND month = DATE '2026-10-01';

-- Q4 Budgets: over-budget categories (BUD-03)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM check_budget(250, DATE '2026-11-01');

-- Q5 Reports page: one user's year by month and category (RPT-02)
EXPLAIN (ANALYZE, BUFFERS)
SELECT DATE_TRUNC('month', t.txn_date)::DATE AS month, c.category_id, SUM(t.amount)
FROM transactions t JOIN categories c ON c.category_id = t.category_id
WHERE c.user_id = 250 AND t.txn_date >= DATE '2026-01-01' AND t.txn_date < DATE '2027-01-01'
GROUP BY 1, 2;

ROLLBACK;   -- the indexes are back

-- ---------------------------------------------------------------------
-- PART 2: WITH the indexes (the same five queries)
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.*, a.account_name, c.name AS category, c.type
FROM transactions t JOIN accounts a ON a.account_id = t.account_id JOIN categories c ON c.category_id = t.category_id
WHERE a.user_id = 250 AND DATE_TRUNC('month', t.txn_date) = DATE '2026-10-01'
ORDER BY t.txn_date DESC, t.transaction_id DESC LIMIT 51;

EXPLAIN (ANALYZE, BUFFERS)
SELECT t.*, a.account_name
FROM transactions t JOIN accounts a ON a.account_id = t.account_id
WHERE a.user_id = 250 AND t.description ILIKE '%imtiaz%'
ORDER BY t.txn_date DESC, t.transaction_id DESC LIMIT 51;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM monthly_summary WHERE user_id = 250 AND month = DATE '2026-10-01';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM check_budget(250, DATE '2026-11-01');

EXPLAIN (ANALYZE, BUFFERS)
SELECT DATE_TRUNC('month', t.txn_date)::DATE AS month, c.category_id, SUM(t.amount)
FROM transactions t JOIN categories c ON c.category_id = t.category_id
WHERE c.user_id = 250 AND t.txn_date >= DATE '2026-01-01' AND t.txn_date < DATE '2027-01-01'
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- PART 3: check_budget(), old query against new query (both with indexes)
-- ---------------------------------------------------------------------
-- old: joins the category_spending view; PostgreSQL works out every user's spending, then keeps one user's
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, b.limit_amount, COALESCE(cs.total_spent, 0) AS spent
FROM budgets b
JOIN categories c ON c.category_id = b.category_id
LEFT JOIN category_spending cs ON cs.category_id = b.category_id AND cs.month = b.month
WHERE b.user_id = 250 AND b.month = DATE '2026-11-01'
  AND COALESCE(cs.total_spent, 0) > b.limit_amount;

-- new (what check_budget() does now): one date range per budget, answered from idx_txn_category_date
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, b.limit_amount, s.spent
FROM budgets b
JOIN categories c ON c.category_id = b.category_id
CROSS JOIN LATERAL (SELECT COALESCE(SUM(t.amount), 0) AS spent FROM transactions t
                    WHERE t.category_id = b.category_id AND t.txn_date >= b.month AND t.txn_date < b.month + INTERVAL '1 month') s
WHERE b.user_id = 250 AND b.month = DATE '2026-11-01'
  AND s.spent > b.limit_amount;

-- ---------------------------------------------------------------------
-- PART 4: FinTrack-wide averages for one year, live against the materialized view (DB-12)
-- ---------------------------------------------------------------------
-- live: reads every transaction of the year
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, c.type, ROUND(SUM(t.amount) / COUNT(DISTINCT c.user_id), 2)
FROM transactions t JOIN categories c ON c.category_id = t.category_id
WHERE t.txn_date >= DATE '2026-01-01' AND t.txn_date < DATE '2027-01-01' AND c.name <> 'Transfer'
GROUP BY DATE_TRUNC('month', t.txn_date), c.name, c.type;

-- materialized view: reads the stored rows
EXPLAIN (ANALYZE, BUFFERS)
SELECT category, type, average_per_user FROM report_monthly_averages
WHERE month >= DATE '2026-01-01' AND month < DATE '2027-01-01';

-- and what one refresh costs (run it, then look at the last row)
SELECT refresh_reports();
SELECT refreshed_at, duration_ms, row_count FROM report_refreshes ORDER BY refresh_id DESC LIMIT 1;
