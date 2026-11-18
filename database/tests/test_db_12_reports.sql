-- DB-12: the FinTrack-wide materialized view report_monthly_averages and refresh_reports().
-- DB-07: the indexes from the performance study exist and are used.
BEGIN;

DO $$
DECLARE
    u INT; acc INT; food INT; first_refresh TIMESTAMPTZ; again TIMESTAMPTZ; plan TEXT := ''; line TEXT;
BEGIN
    ASSERT (SELECT relkind FROM pg_class WHERE relname = 'report_monthly_averages') = 'm', 'DB-12 report_monthly_averages must be a materialized view';
    ASSERT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_report_monthly_averages'), 'DB-12 the unique index for REFRESH CONCURRENTLY must exist';
    RAISE NOTICE 'PASS DB-12 report_monthly_averages is a materialized view with a unique index';

    INSERT INTO users (full_name, email, password_hash) VALUES ('Report', 'report@test.pk', 'x') RETURNING user_id INTO u;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u, 'Cash', 'cash') RETURNING account_id INTO acc;
    INSERT INTO categories (user_id, name, type) VALUES (u, 'Zzz Test Food', 'expense') RETURNING category_id INTO food;
    INSERT INTO transactions (account_id, category_id, amount, txn_date) VALUES (acc, food, 300, '2026-05-10'), (acc, food, 200, '2026-05-20');

    -- a snapshot: new rows are not in it until it is refreshed
    ASSERT NOT EXISTS (SELECT 1 FROM report_monthly_averages WHERE category = 'Zzz Test Food'), 'DB-12 the view must not change before a refresh';
    PERFORM refresh_reports();
    ASSERT (SELECT (users, entries, total, average_per_user) FROM report_monthly_averages WHERE category = 'Zzz Test Food' AND month = '2026-05-01')
           = (1, 2, 500.00::NUMERIC(16,2), 500.00), 'DB-12 after a refresh the new totals must be there';
    RAISE NOTICE 'PASS DB-12 the view is a snapshot until refresh_reports() runs, then shows the new totals';

    first_refresh := (SELECT MAX(refreshed_at) FROM report_refreshes);
    again := refresh_reports(INTERVAL '1 day');
    ASSERT again = first_refresh AND (SELECT COUNT(*) FROM report_refreshes WHERE refreshed_at >= first_refresh) = 1,
           'DB-12 refresh_reports(1 day) must not rebuild a view that is newer than a day';
    RAISE NOTICE 'PASS DB-12 refresh_reports(max_age) skips the rebuild when the view is fresh enough';

    ASSERT NOT has_function_privilege('fintrack_report', 'refresh_reports(interval)', 'EXECUTE'), 'DB-12 the report role must not refresh';
    ASSERT has_function_privilege('fintrack_app', 'refresh_reports(interval)', 'EXECUTE'), 'DB-12 the website must be able to refresh';
    ASSERT has_table_privilege('fintrack_report', 'report_monthly_averages', 'SELECT'), 'DB-12 the report role can read the averages';
    RAISE NOTICE 'PASS DB-12 the website can refresh, the report role can only read';

    -- DB-07: the category + date index answers "spent in this category this month" from the index alone
    ASSERT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_txn_category_date' AND indexdef LIKE '%INCLUDE (amount)%'),
           'DB-07 idx_txn_category_date (category_id, txn_date) INCLUDE (amount) must exist';
    SET LOCAL enable_seqscan = off;   -- the test table is tiny; ask the planner to show it can use the index
    FOR line IN EXECUTE format('EXPLAIN SELECT SUM(amount) FROM transactions WHERE category_id = %s AND txn_date >= %L AND txn_date < %L', food, '2026-05-01', '2026-06-01') LOOP
        plan := plan || line || ' ';
    END LOOP;
    ASSERT plan LIKE '%idx_txn_category_date%', 'DB-07 the budget query must use idx_txn_category_date, got: ' || plan;
    RAISE NOTICE 'PASS DB-07 spending per category and month is read through idx_txn_category_date';

    -- check_budget() (rewritten in step 5) still gives the same answer
    INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (u, food, 400, '2026-05-01');
    ASSERT (SELECT (category, spent, over_by) FROM check_budget(u, '2026-05-15')) = ('Zzz Test Food'::TEXT, 500::NUMERIC, 100::NUMERIC),
           'BUD-03 check_budget must find Rs 500 spent, Rs 100 over';
    ASSERT NOT EXISTS (SELECT 1 FROM check_budget(u, '2026-06-01')), 'BUD-03 nothing is over in a month without spending';
    RAISE NOTICE 'PASS BUD-03 the faster check_budget() gives the same answers';
END
$$;

ROLLBACK;
