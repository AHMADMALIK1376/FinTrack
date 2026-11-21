-- IM-03 - IM-05: SMS import (13_imports.sql): duplicates, suggestions, adding once, remembering choices.
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
    u INT; acc INT; food INT; pay INT; m1 BIGINT; m2 BIGINT; m3 BIGINT; t INT;
BEGIN
    INSERT INTO users (full_name, email, password_hash) VALUES ('IM user', 'im@test.pk', 'x') RETURNING user_id INTO u;
    INSERT INTO accounts (user_id, account_name, account_type) VALUES (u, 'JazzCash wallet', 'wallet') RETURNING account_id INTO acc;
    INSERT INTO categories (user_id, name, type) VALUES (u, 'Food', 'expense') RETURNING category_id INTO food;
    INSERT INTO categories (user_id, name, type) VALUES (u, 'Pay', 'income') RETURNING category_id INTO pay;

    INSERT INTO imported_messages (user_id, sender, body, provider, direction, amount, counterparty, reference, txn_date, category_hint)
    VALUES (u, 'JazzCash', 'Rs 500 paid at KFC. TID 111222333', 'JazzCash', 'out', 500, 'KFC', '111222333', '2026-11-20', 'Food')
    RETURNING import_id INTO m1;
    ASSERT (SELECT (suggested_account_id, suggested_category_id) FROM imported_messages WHERE import_id = m1) = (acc, food),
           'IM-05 suggests the account named after the provider and the category from the hint';
    RAISE NOTICE 'PASS IM-05 a new message gets a suggested account and category';

    PERFORM pg_temp.expect_error(format('INSERT INTO imported_messages (user_id, sender, body, provider, direction, amount, txn_date) VALUES (%s, %L, %L, %L, %L, 500, %L)',
                                        u, 'JazzCash', 'Rs 500 paid at KFC. TID 111222333', 'JazzCash', 'out', '2026-11-20'), '23505',
                                 'IM-03 the same SMS can''t be stored twice');
    INSERT INTO imported_messages (user_id, sender, body, provider, direction, amount, reference, txn_date)
    VALUES (u, 'JazzCash', 'Reminder: Rs 500 at KFC, TID 111222333', 'JazzCash', 'out', 500, '111222333', '2026-11-20') RETURNING import_id INTO m2;
    ASSERT (SELECT (status, duplicate_of) FROM imported_messages WHERE import_id = m2) = ('duplicate'::import_status, m1),
           'IM-03 a second message with the same transaction ID is a duplicate';
    RAISE NOTICE 'PASS IM-03 the same text is kept once, and a repeated transaction ID is marked as a duplicate';

    PERFORM pg_temp.expect_error(format('SELECT add_imported_message(%s, %s, %s, %s)', m1, u, acc, pay), 'P0001',
                                 'IM-04 money going out needs an expense category');
    t := add_imported_message(m1, u, acc, food);
    ASSERT (SELECT (status, transaction_id) FROM imported_messages WHERE import_id = m1) = ('added'::import_status, t), 'IM-04 the message is linked to its transaction';
    ASSERT (SELECT (amount, description) FROM transactions WHERE transaction_id = t) = (500::money_pkr, 'JazzCash · KFC'::VARCHAR), 'IM-04 the transaction has the SMS amount';
    RAISE NOTICE 'PASS IM-04 add_imported_message() makes one transaction with the right type of category';
    PERFORM pg_temp.expect_error(format('SELECT add_imported_message(%s, %s, %s, %s)', m1, u, acc, food), 'P0001',
                                 'IM-04 a message can''t be added twice');

    INSERT INTO imported_messages (user_id, sender, body, provider, direction, amount, counterparty, txn_date)
    VALUES (u, '8558', 'Rs 300 sent to KFC', 'JazzCash', 'out', 300, 'kfc', '2026-11-21') RETURNING import_id INTO m3;
    ASSERT (SELECT suggested_category_id FROM imported_messages WHERE import_id = m3) = food, 'IM-05 the category chosen last time is suggested';
    RAISE NOTICE 'PASS IM-05 the account and category chosen last time are suggested next time';
END
$$;

ROLLBACK;
