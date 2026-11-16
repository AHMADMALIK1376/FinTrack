-- DB-01, DB-02: the six tables exist, each has a primary key, and every relationship is a
-- foreign key with the agreed ON DELETE rule.
BEGIN;

DO $$
DECLARE
    t TEXT;
    rule TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'accounts', 'categories', 'transactions', 'budgets', 'savings_goals'] LOOP
        ASSERT to_regclass('public.' || t) IS NOT NULL, format('DB-01 table %s is missing', t);
        ASSERT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = ('public.' || t)::regclass AND contype = 'p'),
               format('DB-02 table %s has no primary key', t);
    END LOOP;
    RAISE NOTICE 'PASS DB-01 six tables exist';
    RAISE NOTICE 'PASS DB-02 every table has a primary key';

    -- expected foreign keys: child table, column, parent table, ON DELETE action (c = cascade, r = restrict)
    FOR t, rule IN
        SELECT * FROM (VALUES
            ('accounts.user_id>users', 'c'),
            ('categories.user_id>users', 'c'),
            ('transactions.account_id>accounts', 'c'),
            ('transactions.category_id>categories', 'r'),
            ('budgets.user_id>users', 'c'),
            ('budgets.category_id>categories', 'c'),
            ('savings_goals.user_id>users', 'c')) AS v(fk, action)
    LOOP
        ASSERT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
            WHERE c.contype = 'f'
              AND c.conrelid::regclass::text = split_part(t, '.', 1)
              AND a.attname = split_part(split_part(t, '.', 2), '>', 1)
              AND c.confrelid::regclass::text = split_part(t, '>', 2)
              AND c.confdeltype = rule
        ), format('DB-02 foreign key %s with ON DELETE %s is missing', t, rule);
    END LOOP;
    RAISE NOTICE 'PASS DB-02 foreign keys and ON DELETE rules';

    ASSERT (SELECT COUNT(*) FROM pg_indexes
            WHERE indexname IN ('idx_txn_account_date', 'idx_txn_category', 'idx_accounts_user', 'idx_categories_user')) = 4,
           'DB-07 report indexes are missing';
    RAISE NOTICE 'PASS DB-07 report indexes exist';
END
$$;

ROLLBACK;
