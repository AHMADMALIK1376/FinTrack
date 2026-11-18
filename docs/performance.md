# FinTrack performance study (DB-07, DB-12)

How fast are FinTrack's queries with a lot of data, and what do the indexes and the materialized view change?

## Setup

| | |
|---|---|
| Database | PostgreSQL 16, a separate database `fintrack_perf` (never the real one) |
| Data | `database/perf/generate.sql`: **500 users**, 2,000 accounts, 4,500 categories and **285,124 transactions** over 3 years (37 MB). All made up. |
| Queries | `database/perf/explain.sql`: the exact SQL the website runs, for one user (Perf User 250, about 570 transactions) |
| Measure | `EXPLAIN (ANALYZE, BUFFERS)`, "Execution Time", the middle value of 3 runs |

Times depend on the computer; what matters is the size of the difference. To repeat the study, see [Reproduce](#reproduce).

## 1. Indexes: before and after

"Without" = the four indexes dropped inside a transaction that is rolled back afterwards, so nothing is really removed.

| Query (what the website does) | Without indexes | With indexes | Faster |
|---|---:|---:|---:|
| Q1 Transactions page: newest 51 rows of a month | 41.3 ms | 0.34 ms | × 120 |
| Q2 Transactions page: search the description | 64.1 ms | 0.41 ms | × 156 |
| Q3 Dashboard: month's income and expense (`monthly_summary`) | 36.1 ms | 0.32 ms | × 113 |
| Q4 Budgets: `check_budget()` | 45.9 ms | 0.07 ms | × 650 |
| Q5 Reports page: one user's year by month and category | 17.3 ms | 0.20 ms | × 87 |

**Why:** without indexes, every query reads the whole `transactions` table (a *Seq Scan*, about 2,000 pages, run in parallel), and then throws away all but one user's 570 rows. With them, PostgreSQL goes straight to the user's rows:

```
Index Scan using idx_accounts_user on accounts a        Index Cond: (user_id = 250)        -> the user's 4 accounts
  Index Scan using idx_txn_account_date on transactions t   Index Cond: (account_id = a.account_id)  -> their transactions
```

| Index | Columns | Used by |
|---|---|---|
| `idx_accounts_user` | accounts (user_id) | every page: "this user's accounts" |
| `idx_categories_user` | categories (user_id) | categories list, Reports page |
| `idx_txn_account_date` | transactions (account_id, txn_date) | Transactions page, dashboard, search |
| `idx_txn_category_date` *(new, `11_indexes.sql`)* | transactions (category_id, txn_date) **INCLUDE (amount)** | budgets, `check_budget()`, Reports page |

The new index replaces `idx_txn_category (category_id)`. Because it also stores the date and the amount, "how much was spent in this category this month" is answered from the index alone:

```
Index Only Scan using idx_txn_category_date on transactions t
  Index Cond: ((category_id = 2257) AND (txn_date >= '2026-11-01') AND (txn_date < '2026-12-01'))
  Heap Fetches: 0        <- the table itself was not read
```

## 2. A slow query that indexes did not fix: `check_budget()`

The first measurement showed `check_budget()` at **146 ms** even with indexes, while everything else took under 1.5 ms. The old version joined the `category_spending` view:

```sql
LEFT JOIN category_spending cs ON cs.category_id = b.category_id AND cs.month = b.month
```

PostgreSQL could not push "this user's budget" into the view, so it worked out the spending of **all 3,000 expense categories of all 500 users**, then kept one user's. The new version (in `03_views_functions.sql`, and the same change in the budgets list of the API) adds up only the user's budget categories, for one date range:

```sql
CROSS JOIN LATERAL (SELECT COALESCE(SUM(t.amount), 0) AS spent FROM transactions t
                    WHERE t.category_id = b.category_id AND t.txn_date >= b.month AND t.txn_date < b.month + INTERVAL '1 month') s
```

| | Time |
|---|---:|
| Old query, old indexes | 146 ms |
| Old query, with the new index | 39.2 ms |
| **New query, with the new index** | **0.07 ms** (× 560 faster than the old query) |

**Lesson:** an index only helps if the query lets PostgreSQL use it. A date *range* (`txn_date >= … AND txn_date < …`) can use an index on `txn_date`. `DATE_TRUNC('month', txn_date) = …` cannot, and neither can a view that groups everything before filtering.

## 3. The materialized view (DB-12)

The Reports page compares "your average month" with **the average FinTrack user** for each category. That average needs every transaction of every user.

| FinTrack-wide averages for one year | Time |
|---|---:|
| Live query (reads all transactions of the year) | 197 ms |
| From the materialized view `report_monthly_averages` (288 rows) | **0.05 ms** |
| Rebuilding the view: `refresh_reports()` | about 470 ms |

### When to use a materialized view instead of a normal view

| Normal view | Materialized view |
|---|---|
| A saved query: runs again every time it is read | Stores the result: reading it is as fast as reading a small table |
| Always up to date | A snapshot: up to date only after `REFRESH MATERIALIZED VIEW` |
| Good when the query is already fast, or must show the newest data | Good when the query is slow, the result is small and read often, and a slightly old result is acceptable |

FinTrack uses both:

- **One user's own numbers** (dashboard, Reports page): normal views and queries. With the indexes they take well under 1 ms, and a user must see a transaction the moment they add it. A per-user materialized view would hold 121,789 rows (almost half of the transactions table) and would always be out of date. We measured it and did not use it.
- **Averages over all users**: the materialized view. One person's new expense barely changes an average over hundreds of people, so it is rebuilt **at most once a day**:
  - The Reports page calls `refresh_reports('1 day')`, which only rebuilds if the view is older than a day.
  - The daily job `backend/bin/post-recurring.php` rebuilds it every night.
- **`REFRESH MATERIALIZED VIEW CONCURRENTLY`** (it needs the unique index `uq_report_monthly_averages`) lets people keep reading the old rows while the new ones are built.
- **One rebuild at a time:** an advisory lock (`pg_try_advisory_xact_lock`) stops two rebuilds running together.
- **Privacy:** categories used by fewer than 5 people are not shown, so nobody's own spending can be worked out.

## Reproduce

In pgAdmin (or `psql`), as the postgres user:

1. Create a database named **`fintrack_perf`**.
2. Run `database/01_schema.sql` … `11_indexes.sql` in order, **skipping `04_seed.sql`**.
3. Run `database/perf/generate.sql`. It takes about a minute, and refuses to run in any database not named `fintrack_perf`.
4. Run `database/perf/explain.sql` and read each plan's last line, **Execution Time**.

From a terminal:

```bash
createdb -U postgres fintrack_perf
for f in database/0*.sql database/1*.sql; do [ "$(basename "$f")" = 04_seed.sql ] || psql -U postgres -d fintrack_perf -f "$f"; done
psql -U postgres -d fintrack_perf -f database/perf/generate.sql
psql -U postgres -d fintrack_perf -f database/perf/explain.sql
```
