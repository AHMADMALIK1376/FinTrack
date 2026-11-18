-- =====================================================================
-- 09_recurring.sql  -  recurring transactions (TXN-07)
--
-- A recurring transaction is a rule such as "Rent, Rs 40,000 from HBL Bank,
-- every month from 1 Dec". post_due_recurring() turns every rule whose date
-- has come into a normal transaction (the balance and audit triggers run as
-- usual), then moves the rule to its next date.
--
--   * Monthly dates are counted from the start date, so a rule that starts
--     on the 31st posts on 28/29 Feb and on 31 Mar again (it never drifts).
--   * Missed dates are caught up: a weekly rule that was due 3 times since
--     the last run posts 3 transactions, each with its own date.
--   * FOR UPDATE SKIP LOCKED: if two runs start at once (two log-ins, or the
--     daily job and a log-in), each rule is posted by only one of them.
--
-- The website calls post_due_recurring(user_id) when a user logs in or adds
-- a rule; a daily job can call post_due_recurring() for everyone
-- (backend/bin/post-recurring.php).
--
-- Run as the postgres (admin) user, after 01 - 08. Running it again starts
-- the list of rules empty (transactions already posted are kept).
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recurrence_kind') THEN
        CREATE TYPE recurrence_kind AS ENUM ('weekly', 'monthly');
    END IF;
END
$$;

DROP TABLE IF EXISTS recurring_transactions CASCADE;

CREATE TABLE recurring_transactions (
    recurring_id   SERIAL          PRIMARY KEY,
    user_id        INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    account_id     INT             NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    category_id    INT             NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    amount         money_pkr       NOT NULL CONSTRAINT chk_recurring_amount_positive CHECK (amount > 0),
    description    VARCHAR(255),
    frequency      recurrence_kind NOT NULL,
    start_date     DATE            NOT NULL,
    next_run_date  DATE            NOT NULL,
    times_posted   INT             NOT NULL DEFAULT 0 CONSTRAINT chk_recurring_times_posted CHECK (times_posted >= 0),
    is_active      BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_recurring_next_after_start CHECK (next_run_date >= start_date)
);

-- post_due_recurring() looks for active rules whose date has come
CREATE INDEX idx_recurring_due ON recurring_transactions (next_run_date) WHERE is_active;
CREATE INDEX idx_recurring_user ON recurring_transactions (user_id);

COMMENT ON TABLE recurring_transactions IS 'Rules that post a transaction every week or month (TXN-07). Posted by post_due_recurring().';

-- Each posted transaction remembers which rule made it (NULL = added by hand).
-- Dropped and added again so a re-run never points at rules that no longer exist.
ALTER TABLE transactions DROP COLUMN IF EXISTS recurring_id;
ALTER TABLE transactions ADD COLUMN recurring_id INT
    CONSTRAINT fk_transactions_recurring_id REFERENCES recurring_transactions(recurring_id) ON DELETE SET NULL;

-- The rule's account and category must both belong to the rule's user
CREATE OR REPLACE FUNCTION trg_check_recurring_owner()
RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT user_id FROM accounts   WHERE account_id  = NEW.account_id)  IS DISTINCT FROM NEW.user_id
    OR (SELECT user_id FROM categories WHERE category_id = NEW.category_id) IS DISTINCT FROM NEW.user_id THEN
        RAISE EXCEPTION 'The account and category of a recurring transaction must belong to its user';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER recurring_same_owner
BEFORE INSERT OR UPDATE OF user_id, account_id, category_id ON recurring_transactions
FOR EACH ROW EXECUTE FUNCTION trg_check_recurring_owner();

-- The date of the n-th transaction of a rule (n = 0 is the start date)
CREATE OR REPLACE FUNCTION recurring_date(p_start DATE, p_frequency recurrence_kind, p_n INT)
RETURNS DATE
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_frequency
               WHEN 'weekly'  THEN p_start + 7 * p_n
               ELSE (p_start + make_interval(months => p_n))::DATE   -- 31 Jan + 1 month = 28/29 Feb; + 2 months = 31 Mar
           END
$$;

-- Posts every due transaction (for one user, or for everyone when p_user_id is NULL).
-- Returns how many transactions were added.
CREATE OR REPLACE FUNCTION post_due_recurring(p_user_id INT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    r      recurring_transactions%ROWTYPE;
    posted INT := 0;
BEGIN
    FOR r IN
        SELECT * FROM recurring_transactions
        WHERE is_active AND next_run_date <= CURRENT_DATE
          AND (p_user_id IS NULL OR user_id = p_user_id)
        ORDER BY recurring_id
        FOR UPDATE SKIP LOCKED
    LOOP
        WHILE r.next_run_date <= CURRENT_DATE LOOP
            INSERT INTO transactions (account_id, category_id, amount, txn_date, description, recurring_id)
            VALUES (r.account_id, r.category_id, r.amount, r.next_run_date, r.description, r.recurring_id);
            posted := posted + 1;
            r.times_posted  := r.times_posted + 1;
            r.next_run_date := recurring_date(r.start_date, r.frequency, r.times_posted);
        END LOOP;
        UPDATE recurring_transactions
           SET times_posted = r.times_posted, next_run_date = r.next_run_date
         WHERE recurring_id = r.recurring_id;
    END LOOP;
    RETURN posted;
END;
$$;

-- the website's account: manage its rules and post them
GRANT SELECT, INSERT, UPDATE, DELETE ON recurring_transactions TO fintrack_app;
GRANT USAGE, SELECT ON SEQUENCE recurring_transactions_recurring_id_seq TO fintrack_app;
GRANT EXECUTE ON FUNCTION post_due_recurring(INT), recurring_date(DATE, recurrence_kind, INT) TO fintrack_app;
