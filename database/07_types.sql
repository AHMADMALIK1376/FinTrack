-- =====================================================================
-- 07_types.sql  -  object-relational types (DB-11)
--
-- PostgreSQL lets us make our own data types, so a rule is written once
-- and every column that uses the type follows it:
--
--   money_pkr      a DOMAIN: NUMERIC(12,2) with a sanity limit of
--                  Rs 999,999,999.99 either way. Used by every money column.
--   account_kind   an ENUM: bank, cash, wallet, card
--   category_kind  an ENUM: income, expense
--
-- The ENUMs replace the old CHECK (... IN (...)) lists. A wrong value is
-- now refused by the type itself (error 22P02), and pgAdmin shows the
-- allowed values under Types.
--
-- How the columns are changed: ALTER TABLE ... ALTER COLUMN ... TYPE.
-- PostgreSQL refuses to change a column that a view uses, so this script
-- first saves every view's definition and grants (from the system
-- catalogs), drops the views, changes the columns, then recreates the
-- views and their grants exactly as they were.
--
-- Run as the postgres (admin) user, after 01 - 06. Safe to run again:
-- columns that already have the new type are left alone.
-- =====================================================================

-- 1. The types (CREATE TYPE has no IF NOT EXISTS, so we check the catalog)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'money_pkr') THEN
        CREATE DOMAIN money_pkr AS NUMERIC(12,2)
            CONSTRAINT chk_money_pkr_range CHECK (VALUE BETWEEN -999999999.99 AND 999999999.99);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'account_kind') THEN
        CREATE TYPE account_kind AS ENUM ('bank', 'cash', 'wallet', 'card');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'category_kind') THEN
        CREATE TYPE category_kind AS ENUM ('income', 'expense');
    END IF;
END
$$;

COMMENT ON DOMAIN money_pkr     IS 'An amount in Pakistani rupees: 2 decimals, at most Rs 999,999,999.99 either way. Whether it must be positive is decided by each table.';
COMMENT ON TYPE   account_kind  IS 'Kinds of account a user can have.';
COMMENT ON TYPE   category_kind IS 'Whether a category is for money coming in (income) or going out (expense).';

-- 2. Change the columns, keeping the views working
DO $$
DECLARE
    -- table, column, new type
    targets CONSTANT TEXT[][] := ARRAY[
        ['accounts',      'account_type',  'account_kind'],
        ['categories',    'type',          'category_kind'],
        ['accounts',      'balance',       'money_pkr'],
        ['transactions',  'amount',        'money_pkr'],
        ['budgets',       'limit_amount',  'money_pkr'],
        ['savings_goals', 'target_amount', 'money_pkr'],
        ['savings_goals', 'saved_amount',  'money_pkr']];
    todo   INT := 0;
    i      INT;
    v      RECORD;
    saved  JSONB := '[]';
    item   JSONB;
    g      JSONB;
BEGIN
    -- which columns still need changing?
    FOR i IN 1 .. array_length(targets, 1) LOOP
        IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
            WHERE attrelid = targets[i][1]::regclass AND attname = targets[i][2]) <> targets[i][3] THEN
            todo := todo + 1;
        END IF;
    END LOOP;
    IF todo = 0 THEN
        RAISE NOTICE 'All columns already use the FinTrack types; nothing to change.';
        RETURN;
    END IF;

    -- save and drop the views (oldest first, so they can be rebuilt in the same order)
    FOR v IN
        SELECT c.oid, c.relname, pg_get_viewdef(c.oid, true) AS definition, obj_description(c.oid, 'pg_class') AS note
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = 'v'
        ORDER BY c.oid
    LOOP
        saved := saved || jsonb_build_object(
            'name', v.relname, 'definition', v.definition, 'note', v.note,
            'grants', (SELECT COALESCE(jsonb_agg(jsonb_build_object('role', r.rolname, 'privilege', a.privilege_type)), '[]')
                       FROM aclexplode((SELECT relacl FROM pg_class WHERE oid = v.oid)) a
                       JOIN pg_roles r ON r.oid = a.grantee
                       WHERE a.grantee <> (SELECT relowner FROM pg_class WHERE oid = v.oid)));
    END LOOP;
    FOR i IN REVERSE jsonb_array_length(saved) - 1 .. 0 LOOP
        EXECUTE format('DROP VIEW IF EXISTS %I', saved -> i ->> 'name');
    END LOOP;

    -- the old CHECK lists are replaced by the ENUMs
    ALTER TABLE accounts   DROP CONSTRAINT IF EXISTS accounts_account_type_check;
    ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_type_check;

    FOR i IN 1 .. array_length(targets, 1) LOOP
        IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
            WHERE attrelid = targets[i][1]::regclass AND attname = targets[i][2]) <> targets[i][3] THEN
            EXECUTE format('ALTER TABLE %I ALTER COLUMN %I TYPE %s USING %I::%s',
                           targets[i][1], targets[i][2], targets[i][3], targets[i][2], targets[i][3]);
            RAISE NOTICE 'Changed %.% to %', targets[i][1], targets[i][2], targets[i][3];
        END IF;
    END LOOP;

    -- rebuild the views and give back their grants
    FOR item IN SELECT * FROM jsonb_array_elements(saved) LOOP
        EXECUTE format('CREATE VIEW %I AS %s', item ->> 'name', item ->> 'definition');
        IF item ->> 'note' IS NOT NULL THEN
            EXECUTE format('COMMENT ON VIEW %I IS %L', item ->> 'name', item ->> 'note');
        END IF;
        FOR g IN SELECT * FROM jsonb_array_elements(item -> 'grants') LOOP
            EXECUTE format('GRANT %s ON %I TO %I', g ->> 'privilege', item ->> 'name', g ->> 'role');
        END LOOP;
    END LOOP;
END
$$;
