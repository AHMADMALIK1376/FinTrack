-- =====================================================================
-- sms_demo.sql  -  sample forwarded SMS for the demo user (demo@fintrack.pk)
--
-- Run after 04_seed.sql and 13_imports.sql, as the postgres user:
--   psql -U postgres -d fintrack -f database/demo/sms_demo.sql
-- It can be run again: it replaces the demo user's imported messages.
-- Five messages wait in the review inbox (JazzCash, Easypaisa, HBL card, a K-Electric bill,
-- a salary credit); a sixth repeats a transaction ID, so it shows under Duplicates.
-- =====================================================================

DO $$
DECLARE
    v_demo INT := (SELECT user_id FROM users WHERE email = 'demo@fintrack.pk');
    d      DATE := CURRENT_DATE;
BEGIN
    IF v_demo IS NULL THEN
        RAISE EXCEPTION 'Run 04_seed.sql first: the demo user is missing';
    END IF;
    DELETE FROM imported_messages WHERE user_id = v_demo;

    INSERT INTO imported_messages (user_id, sender, body, received_at, provider, direction, amount, counterparty, reference, txn_date, balance_after, category_hint) VALUES
    (v_demo, 'JazzCash', 'You have received Rs 1,500.00 from ALI RAZA 0300xxxxxxx on ' || TO_CHAR(d, 'DD-Mon-YY') || ' at 14:05. TID: 041122334455. New balance: Rs 3,200.50',
        d + TIME '14:05', 'JazzCash', 'in', 1500, 'Ali Raza', '041122334455', d, 3200.50, NULL),
    (v_demo, 'Easypaisa', 'You have successfully sent Rs.1,000 to Bilal Ahmed on ' || TO_CHAR(d - 1, 'DD-MM-YYYY') || '. Trx ID 77665544332. Fee Rs.0. Easypaisa',
        d - 1 + TIME '19:40', 'Easypaisa', 'out', 1000, 'Bilal Ahmed', '77665544332', d - 1, NULL, NULL),
    (v_demo, 'HBL', 'Your HBL Debit Card ending 1234 was used for PKR 2,450.00 at FOODPANDA on ' || TO_CHAR(d - 1, 'DD-Mon-YYYY') || '. Avl Bal PKR 45,210.00',
        d - 1 + TIME '21:12', 'HBL', 'out', 2450, 'Foodpanda', NULL, d - 1, 45210, 'Food'),
    (v_demo, 'JazzCash', 'Your bill payment of Rs 2,340 for K-Electric is successful on ' || TO_CHAR(d - 2, 'DD/MM/YYYY') || '. TID 038877665544.',
        d - 2 + TIME '11:30', 'JazzCash', 'out', 2340, 'K-Electric', '038877665544', d - 2, NULL, 'Bills'),
    (v_demo, 'HBL', 'Your A/C xx1234 has been credited with PKR 120,000.00 on ' || TO_CHAR(d - 3, 'DD-MM-YYYY') || ' Ref No 5544332211. Salary. Avl Bal PKR 150,000.00',
        d - 3 + TIME '09:02', 'HBL', 'in', 120000, NULL, '5544332211', d - 3, 150000, 'Salary'),
    (v_demo, 'JazzCash', 'Reminder: Rs 2,340 paid for K-Electric. TID 038877665544',
        d - 2 + TIME '18:00', 'JazzCash', 'out', 2340, 'K-Electric', '038877665544', d - 2, NULL, 'Bills');

    RAISE NOTICE 'Sample SMS ready. Log in as demo@fintrack.pk / demo1234 and open SMS import.';
END
$$;
