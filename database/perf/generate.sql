-- =====================================================================
-- database/perf/generate.sql  -  fake data for the performance study (DB-07)
--
-- Makes 500 users, each with 4 accounts, the 9 starter categories and
-- 3 years of transactions: 240,000+ transactions in total, plus budgets.
-- All names and amounts are made up.
--
-- Use a SEPARATE database, never your real one:
--   createdb -U postgres fintrack_perf
--   run database/01 ... 11 in order (skip 04_seed.sql), then this file,
--   then database/perf/explain.sql
-- In pgAdmin: create the database "fintrack_perf", open the Query Tool on it,
-- and run the same files. This file takes about a minute.
-- =====================================================================

-- Refuse to run anywhere but fintrack_perf, so real data can't be filled with test rows
DO $$
BEGIN
    IF current_database() <> 'fintrack_perf' THEN
        RAISE EXCEPTION 'Run this only in a database named fintrack_perf (this is "%")', current_database();
    END IF;
END
$$;

SELECT setseed(0.42);   -- the same "random" data every time, so results can be compared

-- Triggers are switched off while loading (much faster); balances are filled in once at the end.
SET session_replication_role = replica;

TRUNCATE users, accounts, categories, transactions, budgets, savings_goals, audit_log, recurring_transactions RESTART IDENTITY CASCADE;

INSERT INTO users (full_name, email, password_hash)
SELECT 'Perf User ' || i, 'perf' || i || '@fintrack.test', 'not-a-real-hash'
FROM generate_series(1, 500) i;

INSERT INTO accounts (user_id, account_name, account_type)
SELECT u.user_id, a.name, a.kind::account_kind
FROM users u
CROSS JOIN (VALUES ('HBL Bank', 'bank'), ('Cash', 'cash'), ('JazzCash', 'wallet'), ('Visa Card', 'card')) a(name, kind);

INSERT INTO categories (user_id, name, type)
SELECT u.user_id, c.name, c.kind::category_kind
FROM users u
CROSS JOIN (VALUES ('Salary', 'income'), ('Freelance', 'income'), ('Other Income', 'income'),
                   ('Food', 'expense'), ('Rent', 'expense'), ('Transport', 'expense'),
                   ('Bills', 'expense'), ('Shopping', 'expense'), ('Health', 'expense')) c(name, kind);

-- 16 transactions a month per user for 3 years (about 280,000 in all, minus future dates): a salary each month, then everyday spending
INSERT INTO transactions (account_id, category_id, amount, txn_date, description)
SELECT acc.account_id, cat.category_id,
       ROUND((CASE WHEN cat.type = 'income' THEN 60000 + random() * 90000 ELSE 150 + random() * 9000 END)::NUMERIC, 2),
       d.day,
       CASE cat.name
           WHEN 'Salary' THEN 'Monthly salary'
           WHEN 'Food' THEN (ARRAY['Groceries at Imtiaz', 'Lunch', 'Dinner out', 'Bakery', 'Fruit and vegetables'])[1 + floor(random() * 5)::INT]
           WHEN 'Transport' THEN (ARRAY['Careem ride', 'Fuel', 'Bus pass', 'Rickshaw'])[1 + floor(random() * 4)::INT]
           WHEN 'Bills' THEN (ARRAY['Electricity bill', 'Gas bill', 'Internet', 'Mobile top-up'])[1 + floor(random() * 4)::INT]
           WHEN 'Rent' THEN 'House rent'
           ELSE cat.name || ' ' || (1 + floor(random() * 50)::INT)
       END
FROM users u
CROSS JOIN LATERAL (
    -- one row per transaction: 16 per month, 36 months. The category and account are chosen here,
    -- once per row (random() in a join condition would be re-run for every candidate row).
    SELECT x.day, x.cat_name,
           CASE WHEN x.cat_name IN ('Salary', 'Freelance', 'Rent') THEN 'HBL Bank'
                ELSE (ARRAY['HBL Bank', 'Cash', 'JazzCash', 'Visa Card'])[1 + floor(random() * 4)::INT] END AS acc_name
    FROM (
        SELECT (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '35 months' + (m || ' months')::INTERVAL)::DATE
               + floor(random() * 28)::INT AS day,
               CASE WHEN k = 1 THEN 'Salary' WHEN k = 2 THEN 'Rent' WHEN k = 3 AND random() < .3 THEN 'Freelance'
                    ELSE (ARRAY['Food', 'Food', 'Food', 'Transport', 'Transport', 'Bills', 'Shopping', 'Health'])[1 + floor(random() * 8)::INT] END AS cat_name
        FROM generate_series(0, 35) m, generate_series(1, 16) k
        WHERE u.user_id > 0   -- refers to u, so this runs again for every user (new random values each time)
    ) x
) d
JOIN categories cat ON cat.user_id = u.user_id AND cat.name = d.cat_name
JOIN accounts   acc ON acc.user_id = u.user_id AND acc.account_name = d.acc_name
WHERE d.day <= CURRENT_DATE;

INSERT INTO budgets (user_id, category_id, limit_amount, month)
SELECT c.user_id, c.category_id, 15000 + (random() * 20000)::INT, DATE_TRUNC('month', CURRENT_DATE)::DATE
FROM categories c WHERE c.type = 'expense' AND c.name IN ('Food', 'Transport', 'Shopping');

SET session_replication_role = DEFAULT;

-- balances in one pass (what the balance trigger would have done row by row)
UPDATE accounts a SET balance = COALESCE(s.total, 0)
FROM (SELECT t.account_id, SUM(CASE WHEN c.type = 'income' THEN t.amount ELSE -t.amount END) AS total
      FROM transactions t JOIN categories c USING (category_id) GROUP BY t.account_id) s
WHERE s.account_id = a.account_id;

-- fresh statistics, so the planner knows the table sizes
VACUUM ANALYZE;

SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM accounts) AS accounts,
       (SELECT count(*) FROM transactions) AS transactions,
       pg_size_pretty(pg_total_relation_size('transactions')) AS transactions_size;
