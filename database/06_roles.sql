-- =====================================================================
-- 06_roles.sql  -  database roles and privileges (DB-10)
--
-- fintrack_app     the account the website (backend/.env) logs in with.
--                  It can read and change FinTrack's data, but it cannot
--                  drop or alter tables, create new ones, or touch the audit
--                  log except by reading it (entries are written by the
--                  SECURITY DEFINER audit trigger, never by the app).
-- fintrack_report  a read-only role for reports: it can read the two report
--                  views and nothing else (not even the tables behind them).
--
-- Run as the postgres (admin) user, after 01 - 05. Safe to run again.
-- Roles belong to the whole PostgreSQL server; the GRANTs apply to the
-- database this script runs in.
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fintrack_app') THEN
        CREATE ROLE fintrack_app LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fintrack_report') THEN
        CREATE ROLE fintrack_report NOLOGIN;
    END IF;
END
$$;

-- Local development password for the website's account. FinTrack only ever runs on our own
-- laptops with fake data; for anything else, choose a new one:
--   ALTER ROLE fintrack_app PASSWORD '<new password>';   and put it in backend/.env
ALTER ROLE fintrack_app PASSWORD 'fintrack_app_local';

-- Start from nothing, then grant only what each role needs.
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO fintrack_app, fintrack_report', current_database());
END
$$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM fintrack_app, fintrack_report;
GRANT USAGE ON SCHEMA public TO fintrack_app, fintrack_report;

-- ---- fintrack_app: day-to-day data, no structure changes
GRANT SELECT, INSERT                 ON users          TO fintrack_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON accounts       TO fintrack_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON categories     TO fintrack_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON transactions   TO fintrack_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON budgets        TO fintrack_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON savings_goals  TO fintrack_app;
GRANT SELECT                         ON audit_log      TO fintrack_app;   -- read only: entries come from the trigger
GRANT SELECT ON monthly_summary, category_spending     TO fintrack_app;
GRANT USAGE, SELECT ON SEQUENCE
    users_user_id_seq, accounts_account_id_seq, categories_category_id_seq,
    transactions_transaction_id_seq, budgets_budget_id_seq, savings_goals_goal_id_seq
    TO fintrack_app;
GRANT EXECUTE ON FUNCTION check_budget(INT, DATE), signed_amount(INT, NUMERIC) TO fintrack_app;
GRANT EXECUTE ON PROCEDURE transfer_money(INT, INT, NUMERIC, VARCHAR) TO fintrack_app;

-- ---- fintrack_report: the report views only
GRANT SELECT ON monthly_summary, category_spending TO fintrack_report;
