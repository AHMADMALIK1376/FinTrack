-- TXN-07: recurring transactions (09_recurring.sql): rules, post_due_recurring(), month-end dates, catch-up, ownership.
BEGIN;

-- expect_error(sql, sqlstates, rule): passes only if the statement fails with one of the error codes
CREATE FUNCTION pg_temp.expect_error(p_sql TEXT, p_state TEXT, p_rule TEXT) RETURNS VOID AS $fn$
DECLARE failed BOOLEAN := FALSE;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF NOT (SQLSTATE = ANY (string_to_array(p_state, ','))) THEN
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
    u1 INT; u2 INT; bank INT; other_acc INT; rent INT; salary INT; other_cat INT;
    weekly INT; monthly INT; paused INT; future INT; n INT;
BEGIN
    -- month-end dates never drift
    ASSERT recurring_date('2026-01-31', 'monthly', 1) = '2026-02-28', 'TXN-07 31 Jan + 1 month must be 28 Feb';
    ASSERT recurring_date('2026-01-31', 'monthly', 2) = '2026-03-31', 'TXN-07 31 Jan + 2 months must be 31 Mar, not 28 Mar';
    ASSERT recurring_date('2027-11-30', 'monthly', 3) = '2028-02-29', 'TXN-07 leap years must give 29 Feb';
    ASSERT recurring_date('2026-12-29', 'weekly', 1) = '2027-01-05', 'TXN-07 weekly adds 7 days across the year end';
    RAISE NOTICE 'PASS TXN-07 monthly dates stay on the start day (31 Jan, 28 Feb, 31 Mar) and weekly adds 7 days';

    INSERT INTO users (full_name, email, password_hash) VALUES ('Rec One', 'rec1@test.pk', 'x') RETURNING user_id INTO u1;
    INSERT INTO users (full_name, email, password_hash) VALUES ('Rec Two', 'rec2@test.pk', 'x') RETURNING user_id INTO u2;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Bank', 'bank') RETURNING account_id INTO bank;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u2, 'Theirs', 'bank') RETURNING account_id INTO other_acc;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Rent', 'expense') RETURNING category_id INTO rent;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Salary', 'income') RETURNING category_id INTO salary;
    INSERT INTO categories (user_id, name, type) VALUES (u2, 'Food', 'expense') RETURNING category_id INTO other_cat;

    -- a weekly rule that started 14 days ago is due 3 times: 14 days ago, 7 days ago and today
    INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, description, frequency, start_date, next_run_date)
    VALUES (u1, bank, rent, 1000, 'Weekly test', 'weekly', CURRENT_DATE - 14, CURRENT_DATE - 14) RETURNING recurring_id INTO weekly;
    INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, description, frequency, start_date, next_run_date)
    VALUES (u1, bank, salary, 50000, 'Monthly salary', 'monthly', CURRENT_DATE, CURRENT_DATE) RETURNING recurring_id INTO monthly;
    INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, frequency, start_date, next_run_date, is_active)
    VALUES (u1, bank, rent, 999, 'weekly', CURRENT_DATE - 7, CURRENT_DATE - 7, FALSE) RETURNING recurring_id INTO paused;
    INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, frequency, start_date, next_run_date)
    VALUES (u1, bank, rent, 777, 'monthly', CURRENT_DATE + 3, CURRENT_DATE + 3) RETURNING recurring_id INTO future;

    n := post_due_recurring(u2);
    ASSERT n = 0, 'TXN-07 posting for another user must not touch these rules';
    n := post_due_recurring(u1);
    ASSERT n = 4, format('TXN-07 expected 3 weekly + 1 monthly transactions, got %s', n);
    ASSERT (SELECT array_agg(txn_date ORDER BY txn_date) FROM transactions WHERE recurring_id = weekly)
           = ARRAY[CURRENT_DATE - 14, CURRENT_DATE - 7, CURRENT_DATE], 'TXN-07 each caught-up transaction gets its own date';
    ASSERT (SELECT next_run_date FROM recurring_transactions WHERE recurring_id = weekly) = CURRENT_DATE + 7, 'TXN-07 the rule moves to its next date';
    ASSERT (SELECT times_posted FROM recurring_transactions WHERE recurring_id = weekly) = 3, 'TXN-07 times_posted counts the transactions';
    ASSERT (SELECT next_run_date FROM recurring_transactions WHERE recurring_id = monthly) = recurring_date(CURRENT_DATE, 'monthly', 1),
           'TXN-07 a monthly rule moves one month on';
    RAISE NOTICE 'PASS TXN-07 due rules are posted, missed weeks are caught up, each with its own date';

    ASSERT NOT EXISTS (SELECT 1 FROM transactions WHERE recurring_id IN (paused, future)), 'TXN-07 paused and future rules post nothing';
    RAISE NOTICE 'PASS TXN-07 paused rules and rules that start later post nothing';

    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 50000 - 3000, 'TXN-07 the balance trigger runs for posted transactions';
    RAISE NOTICE 'PASS TXN-07 posted transactions update the balance like any other (DB-05)';

    ASSERT post_due_recurring(u1) = 0, 'TXN-07 running again the same day posts nothing';
    RAISE NOTICE 'PASS TXN-07 running it again the same day posts nothing twice';

    -- deleting a rule keeps the transactions it already made
    DELETE FROM recurring_transactions WHERE recurring_id = weekly;
    ASSERT (SELECT count(*) FROM transactions WHERE description = 'Weekly test' AND recurring_id IS NULL) = 3, 'TXN-07 posted transactions stay when the rule is deleted';
    RAISE NOTICE 'PASS TXN-07 deleting a rule keeps the transactions it already posted';

    -- ownership and values
    PERFORM pg_temp.expect_error(format('INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, frequency, start_date, next_run_date) VALUES (%s, %s, %s, 10, %L, CURRENT_DATE, CURRENT_DATE)',
                                        u1, other_acc, rent, 'weekly'), 'P0001', 'TXN-07 a rule cannot use another user''s account');
    PERFORM pg_temp.expect_error(format('INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, frequency, start_date, next_run_date) VALUES (%s, %s, %s, 10, %L, CURRENT_DATE, CURRENT_DATE)',
                                        u1, bank, other_cat, 'weekly'), 'P0001', 'TXN-07 a rule cannot use another user''s category');
    PERFORM pg_temp.expect_error(format('INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, frequency, start_date, next_run_date) VALUES (%s, %s, %s, 0, %L, CURRENT_DATE, CURRENT_DATE)',
                                        u1, bank, rent, 'weekly'), '23514', 'TXN-07 a zero amount is refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO recurring_transactions (user_id, account_id, category_id, amount, frequency, start_date, next_run_date) VALUES (%s, %s, %s, 10, %L, CURRENT_DATE, CURRENT_DATE)',
                                        u1, bank, rent, 'daily'), '22P02', 'TXN-07 only weekly or monthly');
    PERFORM pg_temp.expect_error(format('DELETE FROM categories WHERE category_id = %s', salary), '23503,23001', 'TXN-07 a category used by a rule cannot be deleted');
END
$$;

ROLLBACK;
