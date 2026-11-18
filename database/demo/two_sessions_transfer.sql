-- =====================================================================
-- Demo for class (DB-13): two transfers at the same moment
--
-- Story: Demo User has Rs 22,000 in JazzCash. Two transfers of Rs 15,000
-- each start at the same moment (for example, the website open in two
-- tabs). Only one of them should be allowed.
--
-- You need TWO Query Tool windows in pgAdmin, both on the "fintrack"
-- database with the sample data (04_seed.sql). Call them WINDOW 1 and
-- WINDOW 2. Run ONE numbered step at a time: select its lines and press F5.
-- Every step says which window to use.
--
-- Part A shows the problem with a copy of the procedure that does NOT
-- lock the rows. Part B shows FinTrack's real transfer_money(), which
-- locks both account rows with SELECT ... FOR UPDATE.
-- The clean-up steps undo everything, so the sample data is unchanged.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 0 (WINDOW 1): set up two helpers for the demo
-- ---------------------------------------------------------------------
-- demo_account('JazzCash') gives the id of one of Demo User's accounts
CREATE OR REPLACE FUNCTION demo_account(p_name TEXT) RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT a.account_id FROM accounts a JOIN users u USING (user_id)
    WHERE u.email = 'demo@fintrack.pk' AND a.account_name = p_name
$$;

-- The same transfer as transfer_money(), but WITHOUT the row lock (do not use this in the app!)
CREATE OR REPLACE PROCEDURE demo_transfer_without_lock(p_from INT, p_to INT, p_amount NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE v_user INT; v_out INT; v_in INT;
BEGIN
    SELECT user_id INTO v_user FROM accounts WHERE account_id = p_from;
    IF (SELECT balance FROM accounts WHERE account_id = p_from) < p_amount THEN   -- reads the balance, no lock
        RAISE EXCEPTION 'Not enough balance for this transfer';
    END IF;
    SELECT category_id INTO v_out FROM categories WHERE user_id = v_user AND name = 'Transfer' AND type = 'expense';
    SELECT category_id INTO v_in  FROM categories WHERE user_id = v_user AND name = 'Transfer' AND type = 'income';
    INSERT INTO transactions (account_id, category_id, amount, description)
    VALUES (p_from, v_out, p_amount, 'Lock demo'), (p_to, v_in, p_amount, 'Lock demo');
END;
$$;

-- make sure the two "Transfer" categories exist, then look at the balances
INSERT INTO categories (user_id, name, type)
SELECT user_id, 'Transfer', t::category_kind FROM users, unnest(ARRAY['expense', 'income']) t
WHERE email = 'demo@fintrack.pk'
ON CONFLICT DO NOTHING;

SELECT account_name, balance FROM accounts WHERE account_id IN (demo_account('JazzCash'), demo_account('Cash'));
-- JazzCash 22,000 and Cash 7,300


-- =====================================================================
-- PART A: without a lock, both transfers go through
-- =====================================================================

-- STEP A1 (WINDOW 1): start a transaction and send Rs 15,000. Do NOT commit yet.
BEGIN;
CALL demo_transfer_without_lock(demo_account('JazzCash'), demo_account('Cash'), 15000);

-- STEP A2 (WINDOW 2): send another Rs 15,000.
-- It checks the balance (still 22,000 for this session, because WINDOW 1 has not
-- committed), says yes, then waits on the balance update. The query keeps running.
CALL demo_transfer_without_lock(demo_account('JazzCash'), demo_account('Cash'), 15000);

-- STEP A3 (WINDOW 1): commit. WINDOW 2 now finishes too, with no error.
COMMIT;

-- STEP A4 (either window): JazzCash is overdrawn: 22,000 - 15,000 - 15,000 = -8,000
SELECT account_name, balance FROM accounts WHERE account_id IN (demo_account('JazzCash'), demo_account('Cash'));

-- STEP A5 (WINDOW 1): clean up. Deleting the demo rows puts the balances back (the balance trigger).
DELETE FROM transactions WHERE description = 'Lock demo';
SELECT account_name, balance FROM accounts WHERE account_id IN (demo_account('JazzCash'), demo_account('Cash'));


-- =====================================================================
-- PART B: FinTrack's transfer_money() locks the rows, so only one goes through
-- =====================================================================

-- STEP B1 (WINDOW 1): start a transaction and send Rs 15,000. Do NOT commit yet.
-- transfer_money() first runs SELECT ... FOR UPDATE on both accounts, so it now holds their locks.
BEGIN;
CALL transfer_money(demo_account('JazzCash'), demo_account('Cash'), 15000, 'Lock demo');

-- STEP B2 (WINDOW 2): send another Rs 15,000. It stops at SELECT ... FOR UPDATE and waits.
-- (While it waits, STEP B3 in a third window shows the lock.)
CALL transfer_money(demo_account('JazzCash'), demo_account('Cash'), 15000, 'Lock demo');

-- STEP B3 (optional, a third window): who is waiting for whom?
SELECT pid, state, wait_event_type, left(query, 60) AS query, pg_blocking_pids(pid) AS blocked_by
FROM pg_stat_activity
WHERE datname = current_database() AND query ILIKE '%transfer_money%' AND pid <> pg_backend_pid();

-- STEP B4 (WINDOW 1): commit. WINDOW 2 continues, re-reads the balance (now 7,000)
-- and stops with:  ERROR: Not enough balance for this transfer
COMMIT;

-- STEP B5 (either window): JazzCash is 7,000, never below zero
SELECT account_name, balance FROM accounts WHERE account_id IN (demo_account('JazzCash'), demo_account('Cash'));

-- STEP B6 (WINDOW 1): clean up and remove the demo helpers
DELETE FROM transactions WHERE description = 'Lock demo';
DROP PROCEDURE IF EXISTS demo_transfer_without_lock(INT, INT, NUMERIC);
DROP FUNCTION IF EXISTS demo_account(TEXT);
SELECT account_name, balance FROM accounts a JOIN users u USING (user_id) WHERE u.email = 'demo@fintrack.pk' ORDER BY account_id;

-- Why it works: SELECT ... FOR UPDATE takes a row lock that lasts until COMMIT or ROLLBACK.
-- A second FOR UPDATE on the same row waits. In READ COMMITTED (PostgreSQL's default),
-- once it gets the lock it reads the newest committed balance, so the check is made on
-- 7,000, not on the stale 22,000. Locking the two rows in account_id order means two
-- transfers in opposite directions (JazzCash -> Cash and Cash -> JazzCash) can't deadlock.
