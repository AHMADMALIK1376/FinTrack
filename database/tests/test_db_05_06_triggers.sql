-- DB-05: accounts.balance is kept correct by the trigger on INSERT, UPDATE and DELETE.
-- DB-06: a transaction's account and category must belong to the same user.
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
    u1 INT; u2 INT; bank INT; cash INT; salary INT; food INT; other_food INT; t1 INT; t2 INT;
    bal NUMERIC;
BEGIN
    INSERT INTO users (full_name, email, password_hash) VALUES ('Test One', 'dbtest1@test.pk', 'x') RETURNING user_id INTO u1;
    INSERT INTO users (full_name, email, password_hash) VALUES ('Test Two', 'dbtest2@test.pk', 'x') RETURNING user_id INTO u2;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Bank', 'bank') RETURNING account_id INTO bank;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Cash', 'cash') RETURNING account_id INTO cash;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Salary', 'income') RETURNING category_id INTO salary;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Food', 'expense') RETURNING category_id INTO food;
    INSERT INTO categories (user_id, name, type) VALUES (u2, 'Food', 'expense') RETURNING category_id INTO other_food;

    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 0, 'DB-05 a new account starts at 0';

    INSERT INTO transactions (account_id, category_id, amount) VALUES (bank, salary, 50000) RETURNING transaction_id INTO t1;
    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 50000, 'DB-05 income must add to the balance';
    RAISE NOTICE 'PASS DB-05 income adds to the balance';

    INSERT INTO transactions (account_id, category_id, amount) VALUES (bank, food, 1200.50) RETURNING transaction_id INTO t2;
    SELECT balance INTO bal FROM accounts WHERE account_id = bank;
    ASSERT bal = 48799.50, format('DB-05 expense must subtract from the balance, got %s', bal);
    RAISE NOTICE 'PASS DB-05 expense subtracts from the balance';

    UPDATE transactions SET amount = 2000 WHERE transaction_id = t2;
    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 48000, 'DB-05 changing an amount must adjust the balance';
    RAISE NOTICE 'PASS DB-05 changing the amount adjusts the balance';

    UPDATE transactions SET account_id = cash WHERE transaction_id = t2;
    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 50000, 'DB-05 moving an expense must give the old account its money back';
    ASSERT (SELECT balance FROM accounts WHERE account_id = cash) = -2000, 'DB-05 moving an expense must charge the new account';
    RAISE NOTICE 'PASS DB-05 moving a transaction to another account updates both balances';

    UPDATE transactions SET category_id = salary WHERE transaction_id = t2;
    ASSERT (SELECT balance FROM accounts WHERE account_id = cash) = 2000, 'DB-05 changing expense to income must flip its effect';
    RAISE NOTICE 'PASS DB-05 changing the category type flips the effect';

    DELETE FROM transactions WHERE transaction_id = t2;
    ASSERT (SELECT balance FROM accounts WHERE account_id = cash) = 0, 'DB-05 deleting a transaction must undo it';
    DELETE FROM transactions WHERE transaction_id = t1;
    ASSERT (SELECT balance FROM accounts WHERE account_id = bank) = 0, 'DB-05 deleting income must undo it';
    RAISE NOTICE 'PASS DB-05 deleting a transaction undoes it';

    -- DB-06: user 1's account with user 2's category (P0001 = raised by the trigger)
    PERFORM pg_temp.expect_error(format('INSERT INTO transactions (account_id, category_id, amount) VALUES (%s, %s, 10)', bank, other_food), 'P0001', 'DB-06 account and category of different users refused on insert');
    INSERT INTO transactions (account_id, category_id, amount) VALUES (bank, food, 10) RETURNING transaction_id INTO t1;
    PERFORM pg_temp.expect_error(format('UPDATE transactions SET category_id = %s WHERE transaction_id = %s', other_food, t1), 'P0001', 'DB-06 account and category of different users refused on update');
END
$$;

ROLLBACK;
