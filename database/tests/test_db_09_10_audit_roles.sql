-- DB-09: every change to transactions, accounts and budgets is in the append-only audit log,
--        with the row before and after, whose data it is and who changed it.
-- DB-10: the website's role (fintrack_app) can work with data but not change the structure or
--        the log; the report role (fintrack_report) can only read the report views.
BEGIN;

-- expect_error(sql, sqlstates, rule): passes only if the statement fails with one of the error
-- codes in sqlstates (comma-separated: some codes differ between PostgreSQL versions)
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
    u1 INT; bank INT; food INT; salary INT; t1 INT; b1 INT;
    n INT;
    entry RECORD;
BEGIN
    INSERT INTO users (full_name, email, password_hash) VALUES ('Test One', 'dbtest1@test.pk', 'x') RETURNING user_id INTO u1;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Bank', 'bank') RETURNING account_id INTO bank;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Food', 'expense') RETURNING category_id INTO food;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Salary', 'income') RETURNING category_id INTO salary;

    SELECT * INTO entry FROM audit_log WHERE table_name = 'accounts' AND record_id = bank;
    ASSERT entry.action = 'INSERT' AND entry.owner_user_id = u1, 'DB-09 adding an account must be logged for its owner';
    ASSERT entry.changed_by_user_id IS NULL, 'DB-09 a change made directly in the database has no acting user';
    RAISE NOTICE 'PASS DB-09 a change made outside the website is logged with no acting user';

    -- as the website does it: the acting user is set for this transaction
    PERFORM set_config('app.user_id', u1::TEXT, TRUE);

    INSERT INTO transactions (account_id, category_id, amount, description) VALUES (bank, food, 8000, 'Groceries') RETURNING transaction_id INTO t1;
    SELECT * INTO entry FROM audit_log WHERE table_name = 'transactions' AND record_id = t1 AND action = 'INSERT';
    ASSERT entry.changed_by_user_id = u1 AND entry.owner_user_id = u1, 'DB-09 the acting user and owner must be recorded';
    ASSERT entry.new_data ->> 'description' = 'Groceries' AND (entry.new_data ->> 'amount')::NUMERIC = 8000, 'DB-09 the new row must be stored';
    ASSERT entry.old_data IS NULL, 'DB-09 an INSERT has no old row';
    RAISE NOTICE 'PASS DB-09 adding a transaction is logged with who did it';

    ASSERT NOT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'accounts' AND action = 'UPDATE'),
           'DB-09 a balance change made by the balance trigger must not be logged twice';
    RAISE NOTICE 'PASS DB-09 balance-only changes to an account are not logged twice';

    UPDATE transactions SET amount = 8500 WHERE transaction_id = t1;
    SELECT * INTO entry FROM audit_log WHERE table_name = 'transactions' AND record_id = t1 AND action = 'UPDATE';
    ASSERT (entry.old_data ->> 'amount')::NUMERIC = 8000 AND (entry.new_data ->> 'amount')::NUMERIC = 8500, 'DB-09 an UPDATE must store the old and new values';
    RAISE NOTICE 'PASS DB-09 changing a transaction stores the old and the new values';

    UPDATE accounts SET account_name = 'HBL Bank' WHERE account_id = bank;
    ASSERT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'accounts' AND action = 'UPDATE'
                   AND old_data ->> 'account_name' = 'Bank' AND new_data ->> 'account_name' = 'HBL Bank'), 'DB-09 renaming an account must be logged';
    RAISE NOTICE 'PASS DB-09 renaming an account is logged';

    INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (u1, food, 10000, DATE '2026-11-01') RETURNING budget_id INTO b1;
    ASSERT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'budgets' AND record_id = b1 AND action = 'INSERT'), 'DB-09 setting a budget must be logged';
    RAISE NOTICE 'PASS DB-09 setting a budget is logged';

    DELETE FROM transactions WHERE transaction_id = t1;
    SELECT * INTO entry FROM audit_log WHERE table_name = 'transactions' AND record_id = t1 AND action = 'DELETE';
    ASSERT entry.new_data IS NULL AND entry.old_data ->> 'description' = 'Groceries', 'DB-09 a DELETE must keep the deleted row';
    RAISE NOTICE 'PASS DB-09 deleting a transaction keeps a copy of it in the log';

    -- append-only, even for the database owner
    PERFORM pg_temp.expect_error('UPDATE audit_log SET action = ''INSERT''', 'P0001', 'DB-09 log entries cannot be changed');
    PERFORM pg_temp.expect_error('DELETE FROM audit_log', 'P0001', 'DB-09 log entries cannot be deleted');

    SELECT COUNT(*) INTO n FROM audit_log WHERE owner_user_id = u1;
    DELETE FROM users WHERE user_id = u1;
    ASSERT (SELECT COUNT(*) FROM audit_log WHERE owner_user_id = u1) > n, 'DB-09 deleting a user must keep (and add to) their log';
    RAISE NOTICE 'PASS DB-09 the log outlives deleted rows and users';
END
$$;

-- ---- DB-10: the website's role
SET LOCAL ROLE fintrack_app;
DO $$
DECLARE u2 INT; acc INT; cat INT; t INT;
BEGIN
    ASSERT current_user = 'fintrack_app', 'DB-10 test must run as fintrack_app';
    INSERT INTO users (full_name, email, password_hash) VALUES ('App User', 'dbtest-app@test.pk', 'x') RETURNING user_id INTO u2;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u2, 'Cash', 'cash') RETURNING account_id INTO acc;
    INSERT INTO categories (user_id, name, type) VALUES (u2, 'Food', 'expense') RETURNING category_id INTO cat;
    PERFORM set_config('app.user_id', u2::TEXT, TRUE);
    INSERT INTO transactions (account_id, category_id, amount) VALUES (acc, cat, 50) RETURNING transaction_id INTO t;
    ASSERT (SELECT balance FROM accounts WHERE account_id = acc) = -50, 'DB-10 the app role must be able to use the balance trigger';
    ASSERT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'transactions' AND record_id = t AND changed_by_user_id = u2),
           'DB-10 the audit trigger must still write entries for the app role';
    ASSERT (SELECT COUNT(*) FROM check_budget(u2, CURRENT_DATE)) = 0, 'DB-10 the app role must be able to call check_budget()';
    RAISE NOTICE 'PASS DB-10 fintrack_app can read and change data, and its changes are audited';

    PERFORM pg_temp.expect_error('DROP TABLE transactions', '42501', 'DB-10 fintrack_app cannot drop tables');
    PERFORM pg_temp.expect_error('ALTER TABLE accounts ADD COLUMN hacked INT', '42501', 'DB-10 fintrack_app cannot alter tables');
    PERFORM pg_temp.expect_error('CREATE TABLE public.sneaky (id INT)', '42501', 'DB-10 fintrack_app cannot create tables');
    PERFORM pg_temp.expect_error('INSERT INTO audit_log (table_name, record_id, action, new_data) VALUES (''x'', 1, ''INSERT'', ''{}'')', '42501', 'DB-10 fintrack_app cannot write to the audit log directly');
    PERFORM pg_temp.expect_error('DELETE FROM audit_log', '42501', 'DB-10 fintrack_app cannot delete from the audit log');
    PERFORM pg_temp.expect_error('UPDATE users SET full_name = ''x''', '42501', 'DB-10 fintrack_app cannot change user accounts');
END
$$;
RESET ROLE;

-- ---- DB-10: the report role
SET LOCAL ROLE fintrack_report;
DO $$
BEGIN
    PERFORM COUNT(*) FROM monthly_summary;
    PERFORM COUNT(*) FROM category_spending;
    RAISE NOTICE 'PASS DB-10 fintrack_report can read the report views';
    PERFORM pg_temp.expect_error('SELECT COUNT(*) FROM users', '42501', 'DB-10 fintrack_report cannot read the users table');
    PERFORM pg_temp.expect_error('SELECT COUNT(*) FROM transactions', '42501', 'DB-10 fintrack_report cannot read the tables behind the views');
    PERFORM pg_temp.expect_error('DELETE FROM accounts', '42501', 'DB-10 fintrack_report cannot change data');
END
$$;
RESET ROLE;

ROLLBACK;
