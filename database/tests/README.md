# Database tests

Each file checks one group of database rules from the plan (rule IDs in every message).
Every file runs inside `BEGIN … ROLLBACK`, so it **never changes your data**.

**In pgAdmin 4:** open the Query Tool on the `fintrack` database, open a test file and run it (F5).
Each passing check prints `NOTICE: PASS <rule>` in the Messages tab; a failing check stops with an error naming the rule.

**Automatically:** `npm test` in `backend/` rebuilds a test database from `database/0*.sql`, runs these files, then the API tests.
