-- =====================================================================
-- 02_triggers.sql  -  keep accounts.balance correct automatically
-- Income adds to the balance, expense subtracts from it.
-- Works for INSERT, UPDATE (amount, category or account changed) and DELETE.
-- =====================================================================

CREATE OR REPLACE FUNCTION signed_amount(p_category_id INT, p_amount NUMERIC)
RETURNS NUMERIC AS $$
    SELECT CASE WHEN c.type = 'income' THEN p_amount ELSE -p_amount END
    FROM categories c WHERE c.category_id = p_category_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION trg_update_account_balance()
RETURNS TRIGGER AS $$
BEGIN
    -- undo the old row
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        UPDATE accounts
           SET balance = balance - signed_amount(OLD.category_id, OLD.amount)
         WHERE account_id = OLD.account_id;
    END IF;
    -- apply the new row
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        UPDATE accounts
           SET balance = balance + signed_amount(NEW.category_id, NEW.amount)
         WHERE account_id = NEW.account_id;
        RETURN NEW;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS transactions_balance ON transactions;
CREATE TRIGGER transactions_balance
AFTER INSERT OR UPDATE OR DELETE ON transactions
FOR EACH ROW EXECUTE FUNCTION trg_update_account_balance();

-- A transaction's account and category must belong to the same user
CREATE OR REPLACE FUNCTION trg_check_same_owner()
RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT user_id FROM accounts   WHERE account_id  = NEW.account_id) <>
       (SELECT user_id FROM categories WHERE category_id = NEW.category_id) THEN
        RAISE EXCEPTION 'Account % and category % belong to different users',
                        NEW.account_id, NEW.category_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS transactions_same_owner ON transactions;
CREATE TRIGGER transactions_same_owner
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW EXECUTE FUNCTION trg_check_same_owner();
