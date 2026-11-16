-- RPT-01, BUD-03, ACC-04: the report views, check_budget() and the atomic transfer_money() procedure.
BEGIN;

-- expect_error(sql, sqlstate): passes only if the statement fails with that error code
CREATE FUNCTION pg_temp.expect_error(p_sql TEXT, p_state TEXT, p_rule TEXT) RETURNS VOID AS $fn$
DECLARE failed BOOLEAN := FALSE;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> p_state THEN
            RAISE EXCEPTION '% expected error % but got % (%) for: %', p_rule, p_state, SQLSTATE, SQLERRM, p_sql;
        END IF;
        failed := TRUE;
    END;
    IF NOT failed THEN
        RAISE EXCEPTION '% expected error % but the statement succeeded: %', p_rule, p_state, p_sql;
    END IF;
    RAISE NOTICE 'PASS %', p_rule;
END;
$fn$ LANGUAGE plpgsql;

DO $$
DECLARE
    u1 INT; bank INT; cash INT; salary INT; food INT; rent INT;
    m DATE := DATE '2026-03-01';
    s RECORD;
BEGIN
    INSERT INTO users (full_name, email, password_hash) VALUES ('Test One', 'dbtest1@test.pk', 'x') RETURNING user_id INTO u1;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Bank', 'bank') RETURNING account_id INTO bank;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Cash', 'cash') RETURNING account_id INTO cash;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Salary', 'income') RETURNING category_id INTO salary;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Food', 'expense') RETURNING category_id INTO food;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Rent', 'expense') RETURNING category_id INTO rent;

    INSERT INTO transactions (account_id, category_id, amount, txn_date) VALUES
        (bank, salary, 100000, m), (bank, rent, 30000, m + 1), (cash, food, 8000, m + 2), (cash, food, 4000, m + 20),
        (bank, food, 999, m - 1);   -- previous month: must not be counted in March

    SELECT * INTO s FROM monthly_summary WHERE user_id = u1 AND month = m;
    ASSERT s.total_income = 100000, format('RPT-01 March income should be 100000, got %s', s.total_income);
    ASSERT s.total_expense = 42000, format('RPT-01 March expense should be 42000, got %s', s.total_expense);
    ASSERT s.net_saving = 58000, format('RPT-01 March saving should be 58000, got %s', s.net_saving);
    RAISE NOTICE 'PASS RPT-01 monthly_summary totals';

    ASSERT (SELECT total_spent FROM category_spending WHERE category_id = food AND month = m) = 12000, 'RPT-01 category_spending for Food should be 12000';
    ASSERT NOT EXISTS (SELECT 1 FROM category_spending WHERE category_id = salary), 'RPT-01 category_spending must not include income';
    RAISE NOTICE 'PASS RPT-01 category_spending totals';

    INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (u1, food, 10000, m), (u1, rent, 30000, m);
    ASSERT (SELECT COUNT(*) FROM check_budget(u1, m + 10)) = 1, 'BUD-03 exactly one budget (Food) should be over';
    ASSERT (SELECT over_by FROM check_budget(u1, m)) = 2000, 'BUD-03 Food should be over by 2000';
    RAISE NOTICE 'PASS BUD-03 check_budget finds the over-budget category only (spending equal to the limit is not over)';

    -- transfer: bank has 100000 - 30000 - 999 = 69001
    CALL transfer_money(bank, cash, 5000);
    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 64001, 'ACC-04 transfer must take money from the source';
    ASSERT (SELECT balance FROM accounts WHERE account_id = cash) = -7000, 'ACC-04 transfer must add money to the target';
    RAISE NOTICE 'PASS ACC-04 transfer moves money between accounts';

    PERFORM pg_temp.expect_error(format('CALL transfer_money(%s, %s, 1000000)', bank, cash), 'P0001', 'ACC-04 transfer larger than the balance refused');
    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 64001, 'ACC-04 a refused transfer must change nothing';
    RAISE NOTICE 'PASS ACC-04 a refused transfer changes nothing';
END
$$;

ROLLBACK;
