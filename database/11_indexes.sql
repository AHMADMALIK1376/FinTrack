-- =====================================================================
-- 11_indexes.sql  -  indexes from the performance study (DB-07)
--
-- Measured on 285,000 generated transactions (database/perf/, results in
-- docs/performance.md). The indexes from 01_schema.sql already make one
-- user's pages fast (about 1 ms instead of 30 - 110 ms without them).
-- This file swaps one of them for a better one:
--
--   idx_txn_category (category_id)
--     -> idx_txn_category_date (category_id, txn_date) INCLUDE (amount)
--
-- "How much was spent in this category this month?" (budgets, check_budget,
-- the Reports page) is then answered from the index alone, an Index Only
-- Scan: the date range is found in the index, and the amount is stored in
-- it too, so the table itself is not read.
--
-- Run as the postgres (admin) user, after 01 - 10. Safe to run again.
-- =====================================================================

DROP INDEX IF EXISTS idx_txn_category;
CREATE INDEX IF NOT EXISTS idx_txn_category_date ON transactions (category_id, txn_date) INCLUDE (amount);

-- the category foreign key still has an index to use (the first column of the new one),
-- so deleting a category stays fast

ANALYZE transactions;
