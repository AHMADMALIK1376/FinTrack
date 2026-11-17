# Database scripts

Run these in order in **pgAdmin 4 → Query Tool**, connected to a database named `fintrack`:

| File | What it does |
|------|--------------|
| `01_schema.sql` | Creates the 6 tables (3NF) with primary keys, foreign keys, `UNIQUE`, `CHECK` constraints and indexes |
| `02_triggers.sql` | PL/pgSQL triggers: keep `accounts.balance` up to date, and stop a transaction from mixing two users' data |
| `03_views_functions.sql` | Views `monthly_summary` and `category_spending`, function `check_budget()`, procedure `transfer_money()` |
| `04_seed.sql` | Sample users, accounts, categories, transactions, budgets and goals (optional) |
| `05_audit.sql` | Append-only `audit_log` and the generic audit trigger on transactions, accounts and budgets |
| `06_roles.sql` | Roles `fintrack_app` (the website's login, least privilege) and `fintrack_report` (report views only) |

`01_schema.sql` drops and recreates the tables, so running it again resets the database.

## Try these queries

```sql
-- balances are filled in by the trigger
SELECT account_name, balance FROM accounts WHERE user_id = 1;

-- income vs. expense this month
SELECT * FROM monthly_summary WHERE user_id = 1;

-- which budgets are over the limit?
SELECT * FROM check_budget(1, CURRENT_DATE);

-- move Rs 5,000 from HBL Bank to Cash as one atomic unit
CALL transfer_money(1, 2, 5000);

-- the audit log: who changed what (NULL = changed here in pgAdmin, not through the website)
SELECT action, table_name, old_data ->> 'amount' AS old_amount, new_data ->> 'amount' AS new_amount, changed_by_user_id
FROM audit_log ORDER BY audit_id DESC LIMIT 10;

-- see the roles at work
SET ROLE fintrack_report;
SELECT * FROM monthly_summary;     -- allowed
SELECT * FROM users;               -- permission denied
RESET ROLE;

-- the CHECK constraint rejects this
INSERT INTO transactions (account_id, category_id, amount) VALUES (1, 3, -50);
```
