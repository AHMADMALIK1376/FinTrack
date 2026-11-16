-- =====================================================================
-- 04_seed.sql  -  sample data for testing (password for both users: demo1234)
-- =====================================================================

INSERT INTO users (full_name, email, password_hash) VALUES
 ('Demo User',  'demo@fintrack.pk',  '$2a$10$pzfbbQ9X7NqyID1CvQTWUOfxUpiZVQtp4mgH8dP9OhYJE9cxoWCYO'),
 ('Sara Ahmed', 'sara@fintrack.pk',  '$2a$10$pzfbbQ9X7NqyID1CvQTWUOfxUpiZVQtp4mgH8dP9OhYJE9cxoWCYO');

INSERT INTO accounts (user_id, account_name, account_type) VALUES
 (1, 'HBL Bank', 'bank'), (1, 'Cash', 'cash'), (1, 'JazzCash', 'wallet'),
 (2, 'Meezan Bank', 'bank'), (2, 'Cash', 'cash');

INSERT INTO categories (user_id, name, type) VALUES
 (1, 'Salary', 'income'), (1, 'Freelance', 'income'),
 (1, 'Food', 'expense'), (1, 'Rent', 'expense'), (1, 'Transport', 'expense'),
 (1, 'Bills', 'expense'), (1, 'Shopping', 'expense'),
 (2, 'Salary', 'income'), (2, 'Food', 'expense'), (2, 'Transport', 'expense'),
 (1, 'Opening Balance', 'income'), (2, 'Opening Balance', 'income');

-- The trigger fills in every account balance from these rows.
INSERT INTO transactions (account_id, category_id, amount, txn_date, description) VALUES
 (2, 11, 20000, DATE_TRUNC('month', CURRENT_DATE)::DATE,      'Opening balance'),
 (5, 12, 15000, DATE_TRUNC('month', CURRENT_DATE)::DATE,      'Opening balance'),
 (1, 1, 120000, DATE_TRUNC('month', CURRENT_DATE)::DATE,      'Monthly salary'),
 (3, 2,  25000, DATE_TRUNC('month', CURRENT_DATE)::DATE + 4,  'Logo design project'),
 (1, 4,  40000, DATE_TRUNC('month', CURRENT_DATE)::DATE + 1,  'House rent'),
 (2, 3,   8500, DATE_TRUNC('month', CURRENT_DATE)::DATE + 2,  'Groceries'),
 (2, 3,   4200, DATE_TRUNC('month', CURRENT_DATE)::DATE + 6,  'Eating out'),
 (3, 5,   3000, DATE_TRUNC('month', CURRENT_DATE)::DATE + 3,  'Careem rides'),
 (1, 6,   9800, DATE_TRUNC('month', CURRENT_DATE)::DATE + 5,  'Electricity and gas'),
 (1, 7,  12000, DATE_TRUNC('month', CURRENT_DATE)::DATE + 7,  'Clothes'),
 (4, 8,  95000, DATE_TRUNC('month', CURRENT_DATE)::DATE,      'Monthly salary'),
 (5, 9,   7000, DATE_TRUNC('month', CURRENT_DATE)::DATE + 3,  'Groceries');

INSERT INTO budgets (user_id, category_id, limit_amount, month) VALUES
 (1, 3, 10000, DATE_TRUNC('month', CURRENT_DATE)::DATE),   -- Food: will be over budget
 (1, 7, 15000, DATE_TRUNC('month', CURRENT_DATE)::DATE),
 (1, 5,  5000, DATE_TRUNC('month', CURRENT_DATE)::DATE);

INSERT INTO savings_goals (user_id, goal_name, target_amount, saved_amount, deadline) VALUES
 (1, 'New Laptop',       180000, 45000, CURRENT_DATE + 120),
 (1, 'Emergency Fund',   100000, 30000, CURRENT_DATE + 365);
