-- DB-03, DB-04, AUTH-02, GOAL-02, BUD-01: bad data is refused by the database itself.
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
    u1 INT; u2 INT; acc INT; cat_food INT; goal INT;
BEGIN
    INSERT INTO users (full_name, email, password_hash) VALUES ('Test One', 'dbtest1@test.pk', 'x') RETURNING user_id INTO u1;
    INSERT INTO users (full_name, email, password_hash) VALUES ('Test Two', 'dbtest2@test.pk', 'x') RETURNING user_id INTO u2;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Wallet', 'cash') RETURNING account_id INTO acc;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Food', 'expense') RETURNING category_id INTO cat_food;
    INSERT INTO savings_goals (user_id, goal_name, target_amount) VALUES (u1, 'Laptop', 1000) RETURNING goal_id INTO goal;

    -- amounts (23514 = check violation, 23505 = unique violation, 23503 = foreign key violation)
    PERFORM pg_temp.expect_error(format('INSERT INTO transactions (account_id, category_id, amount) VALUES (%s, %s, -5)', acc, cat_food), '23514', 'DB-03 negative amount refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO transactions (account_id, category_id, amount) VALUES (%s, %s, 0)', acc, cat_food), '23514', 'DB-03 zero amount refused');
    ASSERT (SELECT data_type FROM information_schema.columns WHERE table_name = 'transactions' AND column_name = 'amount') = 'numeric',
           'DB-03 transactions.amount must be NUMERIC';
    RAISE NOTICE 'PASS DB-03 money is NUMERIC';

    -- accounts and categories
    PERFORM pg_temp.expect_error(format('INSERT INTO accounts (user_id, account_name, account_type) VALUES (%s, %L, %L)', u1, 'Wallet', 'bank'), '23505', 'DB-04 duplicate account name for one user refused');
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u2, 'Wallet', 'cash');
    RAISE NOTICE 'PASS DB-04 same account name allowed for another user';
    PERFORM pg_temp.expect_error(format('INSERT INTO accounts (user_id, account_name, account_type) VALUES (%s, %L, %L)', u1, 'Gold', 'crypto'), '22P02', 'ACC-01 unknown account type refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO categories (user_id, name, type) VALUES (%s, %L, %L)', u1, 'Food', 'expense'), '23505', 'DB-04 duplicate category refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO categories (user_id, name, type) VALUES (%s, %L, %L)', u1, 'Gifts', 'transfer'), '22P02', 'DB-04 unknown category type refused');

    -- users
    PERFORM pg_temp.expect_error('INSERT INTO users (full_name, email, password_hash) VALUES (''X'', ''dbtest1@test.pk'', ''x'')', '23505', 'AUTH-02 duplicate e-mail refused');
    PERFORM pg_temp.expect_error('INSERT INTO users (full_name, email, password_hash) VALUES (''X'', ''not-an-email'', ''x'')', '23514', 'AUTH-02 badly formed e-mail refused');
    PERFORM pg_temp.expect_error('INSERT INTO users (full_name, email, password_hash) VALUES (NULL, ''n@test.pk'', ''x'')', '23502', 'DB-04 missing name refused');

    -- budgets
    PERFORM pg_temp.expect_error(format('INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (%s, %s, 0, %L)', u1, cat_food, '2026-11-01'), '23514', 'BUD-01 zero budget refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (%s, %s, 500, %L)', u1, cat_food, '2026-11-15'), '23514', 'BUD-01 budget month must be the 1st');
    INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (u1, cat_food, 500, '2026-11-01');
    PERFORM pg_temp.expect_error(format('INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES (%s, %s, 700, %L)', u1, cat_food, '2026-11-01'), '23505', 'BUD-01 one budget per category per month');

    -- goals
    PERFORM pg_temp.expect_error(format('UPDATE savings_goals SET saved_amount = 1500 WHERE goal_id = %s', goal), '23514', 'GOAL-02 saved amount above target refused');
    PERFORM pg_temp.expect_error(format('UPDATE savings_goals SET saved_amount = -1 WHERE goal_id = %s', goal), '23514', 'GOAL-02 negative saved amount refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO savings_goals (user_id, goal_name, target_amount) VALUES (%s, %L, 0)', u1, 'Nothing'), '23514', 'GOAL-02 zero target refused');

    -- ON DELETE rules
    INSERT INTO transactions (account_id, category_id, amount) VALUES (acc, cat_food, 100);
    PERFORM pg_temp.expect_error(format('DELETE FROM categories WHERE category_id = %s', cat_food), '23503,23001', 'DB-02 category used by transactions cannot be deleted');
    DELETE FROM users WHERE user_id = u1;
    ASSERT NOT EXISTS (SELECT 1 FROM accounts WHERE user_id = u1), 'DB-02 deleting a user must delete their accounts';
    ASSERT NOT EXISTS (SELECT 1 FROM savings_goals WHERE user_id = u1), 'DB-02 deleting a user must delete their goals';
    RAISE NOTICE 'PASS DB-02 deleting a user removes all their data';
END
$$;

ROLLBACK;
