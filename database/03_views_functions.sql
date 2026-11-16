-- =====================================================================
-- 03_views_functions.sql  -  reports used by the dashboard
-- =====================================================================

-- Income vs. expense per user per month
CREATE OR REPLACE VIEW monthly_summary AS
SELECT a.user_id,
       DATE_TRUNC('month', t.txn_date)::DATE                              AS month,
       COALESCE(SUM(t.amount) FILTER (WHERE c.type = 'income'),  0)       AS total_income,
       COALESCE(SUM(t.amount) FILTER (WHERE c.type = 'expense'), 0)       AS total_expense,
       COALESCE(SUM(t.amount) FILTER (WHERE c.type = 'income'),  0)
     - COALESCE(SUM(t.amount) FILTER (WHERE c.type = 'expense'), 0)       AS net_saving
FROM transactions t
JOIN accounts   a ON a.account_id  = t.account_id
JOIN categories c ON c.category_id = t.category_id
GROUP BY a.user_id, DATE_TRUNC('month', t.txn_date);

-- Total spent per expense category per month
CREATE OR REPLACE VIEW category_spending AS
SELECT c.user_id,
       c.category_id,
       c.name                                   AS category,
       DATE_TRUNC('month', t.txn_date)::DATE    AS month,
       SUM(t.amount)                            AS total_spent
FROM transactions t
JOIN categories c ON c.category_id = t.category_id
WHERE c.type = 'expense'
GROUP BY c.user_id, c.category_id, c.name, DATE_TRUNC('month', t.txn_date);

-- Budgets that are over the limit for a user in a given month
CREATE OR REPLACE FUNCTION check_budget(p_user_id INT, p_month DATE)
RETURNS TABLE (category TEXT, limit_amount NUMERIC, spent NUMERIC, over_by NUMERIC) AS $$
    SELECT c.name::TEXT,
           b.limit_amount,
           COALESCE(cs.total_spent, 0),
           COALESCE(cs.total_spent, 0) - b.limit_amount
    FROM budgets b
    JOIN categories c ON c.category_id = b.category_id
    LEFT JOIN category_spending cs
           ON cs.category_id = b.category_id
          AND cs.month = b.month
    WHERE b.user_id = p_user_id
      AND b.month   = DATE_TRUNC('month', p_month)::DATE
      AND COALESCE(cs.total_spent, 0) > b.limit_amount;
$$ LANGUAGE sql STABLE;

-- Move money between two accounts of the same user as ONE unit of work.
-- Either both rows are written or neither is (atomic).
CREATE OR REPLACE PROCEDURE transfer_money(
    p_from_account INT, p_to_account INT, p_amount NUMERIC, p_note VARCHAR DEFAULT 'Transfer')
LANGUAGE plpgsql AS $$
DECLARE
    v_user INT;
    v_out  INT;
    v_in   INT;
BEGIN
    SELECT user_id INTO v_user FROM accounts WHERE account_id = p_from_account;
    IF v_user IS NULL OR v_user <> (SELECT user_id FROM accounts WHERE account_id = p_to_account) THEN
        RAISE EXCEPTION 'Both accounts must exist and belong to the same user';
    END IF;
    IF (SELECT balance FROM accounts WHERE account_id = p_from_account) < p_amount THEN
        RAISE EXCEPTION 'Not enough balance for this transfer';
    END IF;

    -- get or create the two "Transfer" categories for this user
    INSERT INTO categories (user_id, name, type) VALUES (v_user, 'Transfer', 'expense')
        ON CONFLICT (user_id, name, type) DO NOTHING;
    INSERT INTO categories (user_id, name, type) VALUES (v_user, 'Transfer', 'income')
        ON CONFLICT (user_id, name, type) DO NOTHING;
    SELECT category_id INTO v_out FROM categories WHERE user_id = v_user AND name = 'Transfer' AND type = 'expense';
    SELECT category_id INTO v_in  FROM categories WHERE user_id = v_user AND name = 'Transfer' AND type = 'income';

    INSERT INTO transactions (account_id, category_id, amount, description)
    VALUES (p_from_account, v_out, p_amount, p_note),
           (p_to_account,   v_in,  p_amount, p_note);
END;
$$;
