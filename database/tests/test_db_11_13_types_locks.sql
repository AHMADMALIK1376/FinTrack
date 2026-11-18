-- DB-11: object-relational types (07_types.sql): the money_pkr domain and the account_kind / category_kind enums.
-- ACC-04 / DB-13: transfer_money() refuses bad input before locking anything.
-- (The two-session locking test is in backend/tests/concurrency.test.js, because it needs two connections.)
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
    u1 INT; acc INT; acc2 INT; cat INT;
BEGIN
    -- the types exist and the columns use them
    ASSERT (SELECT typtype FROM pg_type WHERE typname = 'money_pkr') = 'd', 'DB-11 money_pkr must be a DOMAIN';
    ASSERT (SELECT array_agg(enumlabel ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'account_kind'::regtype)
           = ARRAY['bank', 'cash', 'wallet', 'card']::NAME[], 'DB-11 account_kind must list bank, cash, wallet, card';
    ASSERT (SELECT array_agg(enumlabel ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'category_kind'::regtype)
           = ARRAY['income', 'expense']::NAME[], 'DB-11 category_kind must list income, expense';
    RAISE NOTICE 'PASS DB-11 money_pkr domain and the two enum types exist';

    ASSERT (SELECT count(*) FROM information_schema.columns
            WHERE domain_name = 'money_pkr' AND table_schema = 'public'
              AND (table_name, column_name) IN (('accounts', 'balance'), ('transactions', 'amount'), ('budgets', 'limit_amount'),
                                                ('savings_goals', 'target_amount'), ('savings_goals', 'saved_amount'))) = 5,
           'DB-11 every money column must use money_pkr';
    ASSERT (SELECT udt_name FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'account_type') = 'account_kind',
           'DB-11 accounts.account_type must be account_kind';
    ASSERT (SELECT udt_name FROM information_schema.columns WHERE table_name = 'categories' AND column_name = 'type') = 'category_kind',
           'DB-11 categories.type must be category_kind';
    RAISE NOTICE 'PASS DB-11 money, account type and category type columns use the new types';

    INSERT INTO users (full_name, email, password_hash) VALUES ('Types', 'types@test.pk', 'x') RETURNING user_id INTO u1;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Bank', 'bank') RETURNING account_id INTO acc;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u1, 'Cash', 'cash') RETURNING account_id INTO acc2;
    INSERT INTO categories (user_id, name, type) VALUES (u1, 'Salary', 'income') RETURNING category_id INTO cat;

    -- 22P02 = invalid input value for an enum, 23514 = check violation (the domain's range), 22003 = number too large
    PERFORM pg_temp.expect_error(format('INSERT INTO accounts (user_id, account_name, account_type) VALUES (%s, %L, %L)', u1, 'Gold', 'crypto'), '22P02',
                                 'DB-11 an account type outside account_kind is refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO categories (user_id, name, type) VALUES (%s, %L, %L)', u1, 'Gift', 'gift'), '22P02',
                                 'DB-11 a category type outside category_kind is refused');
    PERFORM pg_temp.expect_error(format('INSERT INTO transactions (account_id, category_id, amount) VALUES (%s, %s, 1000000000)', acc, cat), '23514,22003',
                                 'DB-11 money_pkr refuses an amount over Rs 999,999,999.99');
    INSERT INTO transactions (account_id, category_id, amount) VALUES (acc, cat, 1234.567);
    ASSERT (SELECT balance FROM accounts WHERE account_id = acc) = 1234.57, 'DB-11 money_pkr keeps 2 decimals';
    RAISE NOTICE 'PASS DB-11 money_pkr rounds to 2 decimals';
    ASSERT (SELECT array_agg(type ORDER BY type) FROM (VALUES ('expense'::category_kind), ('income')) v(type)) = ARRAY['income', 'expense']::category_kind[],
           'DB-11 enums sort in their declared order';
    RAISE NOTICE 'PASS DB-11 enum values sort in their declared order (income before expense)';

    -- transfer_money checks its input first
    PERFORM pg_temp.expect_error(format('CALL transfer_money(%s, %s, 0)', acc, acc2), 'P0001', 'ACC-04 a transfer of zero is refused');
    PERFORM pg_temp.expect_error(format('CALL transfer_money(%s, %s, 10)', acc, acc), 'P0001', 'ACC-04 a transfer to the same account is refused');
    CALL transfer_money(acc, acc2, 234.57);
    ASSERT (SELECT balance FROM accounts WHERE account_id = acc) = 1000 AND (SELECT balance FROM accounts WHERE account_id = acc2) = 234.57,
           'ACC-04 a valid transfer still moves the money';
    RAISE NOTICE 'PASS ACC-04 a valid transfer still works with the row locks';
END
$$;

ROLLBACK;
