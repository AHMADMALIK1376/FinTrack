-- =====================================================================
-- 10_reports.sql  -  FinTrack-wide report as a MATERIALIZED VIEW (DB-12)
--
-- report_monthly_averages: for every month and category name, how many
-- users spent (or earned) in it and the average per user. The Reports page
-- uses it to show "you vs the average FinTrack user".
--
-- Why a materialized view here, and not a normal view?
--   * A normal view is a saved query: it runs again every time it is read.
--     Averages over ALL users have to read every transaction (285,000 rows
--     in the performance test: about 150 ms each time).
--   * A materialized view stores the result (a few hundred rows), so reading
--     it takes well under 1 ms. The price: it is a snapshot, so it must be
--     refreshed, and between refreshes it can be out of date.
--   * That is fine for averages over many users (one person's new expense
--     barely moves them), so we refresh at most once a day.
--   * One user's own report is NOT materialized: with the indexes it is
--     about 1 ms live, and it must show their newest transaction at once.
--
-- refresh_reports(max_age) rebuilds it if it is older than max_age.
-- REFRESH ... CONCURRENTLY lets people keep reading the old rows while the
-- new ones are built (it needs the unique index below).
--
-- Run as the postgres (admin) user, after 01 - 09. Safe to run again.
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS report_monthly_averages;

CREATE MATERIALIZED VIEW report_monthly_averages AS
SELECT DATE_TRUNC('month', t.txn_date)::DATE           AS month,
       c.name::TEXT                                    AS category,
       c.type,
       COUNT(DISTINCT c.user_id)::INT                  AS users,
       COUNT(*)::INT                                   AS entries,
       SUM(t.amount)::NUMERIC(16,2)                    AS total,
       ROUND(SUM(t.amount) / COUNT(DISTINCT c.user_id), 2) AS average_per_user
FROM transactions t
JOIN categories c ON c.category_id = t.category_id
WHERE c.name <> 'Transfer'                             -- moving money between your own accounts is not income or spending
GROUP BY 1, 2, 3
WITH DATA;

-- needed for REFRESH ... CONCURRENTLY, and makes lookups by month fast
CREATE UNIQUE INDEX uq_report_monthly_averages ON report_monthly_averages (month, category, type);

COMMENT ON MATERIALIZED VIEW report_monthly_averages IS
    'Average per user, per month and category name, over all users (DB-12). A snapshot: refreshed by refresh_reports().';

-- when the report was last rebuilt, and how long it took
DROP TABLE IF EXISTS report_refreshes;
CREATE TABLE report_refreshes (
    refresh_id    SERIAL       PRIMARY KEY,
    refreshed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    duration_ms   NUMERIC(10,1) NOT NULL,
    row_count     INT          NOT NULL
);
INSERT INTO report_refreshes (duration_ms, row_count) SELECT 0, COUNT(*) FROM report_monthly_averages;

-- Rebuilds the report if it is older than p_max_age (0 = always). Returns when it was last built.
-- SECURITY DEFINER: runs with the owner's rights, so the website's account can refresh the view
-- without owning it. search_path is fixed so nobody can swap in their own tables.
CREATE OR REPLACE FUNCTION refresh_reports(p_max_age INTERVAL DEFAULT INTERVAL '0')
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_last    TIMESTAMPTZ;
    v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT MAX(refreshed_at) INTO v_last FROM report_refreshes;
    IF v_last IS NOT NULL AND v_last > NOW() - p_max_age THEN
        RETURN v_last;                         -- fresh enough
    END IF;
    -- one refresh at a time: if another session is already refreshing, use what is there
    IF NOT pg_try_advisory_xact_lock(hashtext('fintrack.refresh_reports')) THEN
        RETURN v_last;
    END IF;
    REFRESH MATERIALIZED VIEW CONCURRENTLY report_monthly_averages;
    INSERT INTO report_refreshes (duration_ms, row_count)
    VALUES (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000, (SELECT COUNT(*) FROM report_monthly_averages));
    DELETE FROM report_refreshes WHERE refreshed_at < NOW() - INTERVAL '30 days';
    RETURN NOW();
END;
$$;

REVOKE EXECUTE ON FUNCTION refresh_reports(INTERVAL) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION refresh_reports(INTERVAL) TO fintrack_app;
GRANT  SELECT ON report_monthly_averages, report_refreshes TO fintrack_app;
GRANT  SELECT ON report_monthly_averages TO fintrack_report;   -- the read-only reporting role can use it too
