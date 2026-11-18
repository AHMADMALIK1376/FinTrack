-- =====================================================================
-- 05_audit.sql  -  audit log (DB-09)
-- Every INSERT, UPDATE and DELETE on transactions, accounts and budgets is
-- written to audit_log with the row before and after the change (JSONB),
-- whose data it is, and who made the change.
--
-- Who made the change: the API runs every change inside a transaction that
-- first sets   SELECT set_config('app.user_id', '<id>', true);
-- A change made directly in pgAdmin has no app.user_id, so changed_by_user_id
-- is NULL ("changed directly in the database").
--
-- Run after 01 - 03 (and 04 if you want sample data; sample rows are not logged).
-- Re-running this script starts a new, empty log.
-- =====================================================================

DROP TABLE IF EXISTS audit_log CASCADE;

CREATE TABLE audit_log (
    audit_id            BIGSERIAL    PRIMARY KEY,
    table_name          VARCHAR(40)  NOT NULL,
    record_id           INT          NOT NULL,
    action              VARCHAR(10)  NOT NULL,
    old_data            JSONB,                    -- row before the change (NULL for INSERT)
    new_data            JSONB,                    -- row after the change  (NULL for DELETE)
    owner_user_id       INT,                      -- whose data this is
    changed_by_user_id  INT,                      -- who changed it (NULL = directly in the database)
    changed_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_audit_log_action CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    CONSTRAINT chk_audit_log_data CHECK (
        (action = 'INSERT' AND old_data IS NULL AND new_data IS NOT NULL) OR
        (action = 'UPDATE' AND old_data IS NOT NULL AND new_data IS NOT NULL) OR
        (action = 'DELETE' AND old_data IS NOT NULL AND new_data IS NULL))
);
-- owner_user_id and changed_by_user_id are logical links to users, deliberately WITHOUT
-- foreign keys: the log must outlive the rows it describes, including deleted users.

CREATE INDEX idx_audit_log_owner_changed_at ON audit_log (owner_user_id, changed_at DESC);
CREATE INDEX idx_audit_log_table_record     ON audit_log (table_name, record_id);

COMMENT ON TABLE audit_log IS 'Append-only history of changes to transactions, accounts and budgets (DB-09).';


-- ---------------------------------------------------------------------
-- The log is append-only: nobody may change or remove an entry.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_log_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'The audit log cannot be changed or deleted';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_log_append_only
BEFORE UPDATE OR DELETE ON audit_log
FOR EACH ROW EXECUTE FUNCTION trg_audit_log_append_only();


-- ---------------------------------------------------------------------
-- One generic audit trigger for every audited table.
--   TG_ARGV[0]  name of the table's primary key column
--   TG_ARGV[1]  (optional) comma-separated columns to ignore: an UPDATE that only
--               changes these is not logged (accounts.balance is changed by the
--               balance trigger on every transaction; that is already logged there)
-- SECURITY DEFINER: runs with the rights of the function's owner, so the website's
-- database role can write log entries without having INSERT on audit_log itself.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_row()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    pk_column   TEXT    := TG_ARGV[0];
    ignored     TEXT[]  := COALESCE(string_to_array(TG_ARGV[1], ','), ARRAY[]::TEXT[]);
    old_row     JSONB   := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END;
    new_row     JSONB   := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END;
    the_row     JSONB   := COALESCE(new_row, old_row);
    acting_user INT     := NULLIF(current_setting('app.user_id', TRUE), '')::INT;
    owner       INT;
BEGIN
    -- skip updates that only touched ignored columns
    IF TG_OP = 'UPDATE' AND (old_row - ignored) = (new_row - ignored) THEN
        RETURN NULL;
    END IF;

    -- whose data is it?
    IF the_row ? 'user_id' THEN
        owner := (the_row ->> 'user_id')::INT;
    ELSIF the_row ? 'account_id' THEN
        SELECT a.user_id INTO owner FROM accounts a WHERE a.account_id = (the_row ->> 'account_id')::INT;
    END IF;
    -- the account may already be gone (cascade delete): then it is the acting user's data
    owner := COALESCE(owner, acting_user);

    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, owner_user_id, changed_by_user_id)
    VALUES (TG_TABLE_NAME, (the_row ->> pk_column)::INT, TG_OP, old_row, new_row, owner, acting_user);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS transactions_audit ON transactions;
CREATE TRIGGER transactions_audit
AFTER INSERT OR UPDATE OR DELETE ON transactions
FOR EACH ROW EXECUTE FUNCTION trg_audit_row('transaction_id');

DROP TRIGGER IF EXISTS accounts_audit ON accounts;
CREATE TRIGGER accounts_audit
AFTER INSERT OR UPDATE OR DELETE ON accounts
FOR EACH ROW EXECUTE FUNCTION trg_audit_row('account_id', 'balance');

DROP TRIGGER IF EXISTS budgets_audit ON budgets;
CREATE TRIGGER budgets_audit
AFTER INSERT OR UPDATE OR DELETE ON budgets
FOR EACH ROW EXECUTE FUNCTION trg_audit_row('budget_id');
