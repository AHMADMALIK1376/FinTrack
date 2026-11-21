-- =====================================================================
-- 13_imports.sql  -  Import transactions from SMS (IM-01 - IM-07)
--
-- The user's phone forwards bank, JazzCash and Easypaisa SMS to a private
-- FinTrack address. FinTrack reads each message and puts it in a review inbox;
-- nothing is added to the user's accounts until they approve it.
--
--   sms_keys                        one private forwarding key per user (only its SHA-256 hash is kept)
--   imported_messages               the review inbox: what each SMS says, and what happened to it
--   import_provider_accounts        remembered: "JazzCash messages go to my JazzCash account"
--   import_counterparty_categories  remembered: "money paid to Foodpanda is Food"
--
-- In the database:
--   * the same SMS forwarded twice is kept once (UNIQUE on a hash of the text)
--   * a second message with the same transaction ID is marked as a duplicate (trigger)
--   * add_imported_message() adds a message as a transaction exactly once, under a row lock,
--     checks the account, the category and its type, and remembers the choices for next time
--
-- Run as the postgres (admin) user, after 01 - 12.
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'import_status') THEN
        CREATE TYPE import_status AS ENUM ('pending', 'added', 'ignored', 'duplicate');
    END IF;
END
$$;

DROP TABLE IF EXISTS import_counterparty_categories, import_provider_accounts, imported_messages, sms_keys CASCADE;

CREATE TABLE sms_keys (
    user_id       INT          PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    token_hash    CHAR(64)     NOT NULL UNIQUE,           -- SHA-256 of the key; the key itself is shown to the user once
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    last_used_at  TIMESTAMPTZ
);

CREATE TABLE imported_messages (
    import_id              BIGSERIAL     PRIMARY KEY,
    user_id                INT           NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    source                 VARCHAR(10)   NOT NULL DEFAULT 'sms' CHECK (source IN ('sms', 'test')),
    sender                 VARCHAR(40)   NOT NULL DEFAULT '',
    body                   TEXT          NOT NULL CHECK (LENGTH(body) BETWEEN 1 AND 1000),
    body_hash              CHAR(32)      GENERATED ALWAYS AS (md5(sender || E'\n' || body)) STORED,
    received_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    -- what FinTrack read in the message
    provider               VARCHAR(30)   NOT NULL,                     -- JazzCash, Easypaisa, HBL, Meezan Bank ...
    direction              VARCHAR(3)    NOT NULL CHECK (direction IN ('in', 'out')),
    amount                 money_pkr     NOT NULL CHECK (amount > 0),
    counterparty           VARCHAR(100),
    reference              VARCHAR(40),                                -- the TID / Trx ID, when the SMS has one
    txn_date               DATE          NOT NULL,
    balance_after          NUMERIC(14, 2),
    category_hint          VARCHAR(40),                                -- e.g. 'Food' for Foodpanda; matched to the user's categories
    -- suggestions, filled in by the trigger below
    suggested_account_id   INT           REFERENCES accounts(account_id) ON DELETE SET NULL,
    suggested_category_id  INT           REFERENCES categories(category_id) ON DELETE SET NULL,
    -- what the user decided
    status                 import_status NOT NULL DEFAULT 'pending',
    duplicate_of           BIGINT        REFERENCES imported_messages(import_id) ON DELETE SET NULL,
    transaction_id         INT           REFERENCES transactions(transaction_id) ON DELETE SET NULL,
    decided_at             TIMESTAMPTZ,
    CONSTRAINT uq_imported_message UNIQUE (user_id, body_hash)
);
CREATE INDEX idx_imported_messages_inbox ON imported_messages (user_id, status, received_at DESC);
CREATE INDEX idx_imported_messages_ref ON imported_messages (user_id, provider, reference) WHERE reference IS NOT NULL;

CREATE TABLE import_provider_accounts (
    user_id     INT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    provider    VARCHAR(30)  NOT NULL,
    account_id  INT          NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, provider)
);

CREATE TABLE import_counterparty_categories (
    user_id      INT           NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    counterparty VARCHAR(100)  NOT NULL,          -- lower case
    direction    VARCHAR(3)    NOT NULL CHECK (direction IN ('in', 'out')),
    category_id  INT           NOT NULL REFERENCES categories(category_id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, counterparty, direction)
);

COMMENT ON TABLE imported_messages IS 'IM-02: the SMS review inbox. Nothing reaches transactions until the user adds it (IM-04).';

-- ---------------------------------------------------------------------
-- Before a message is saved: catch duplicates and suggest an account and a category (IM-03, IM-05)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_imported_message_prepare()
RETURNS TRIGGER AS $$
DECLARE
    v_kind category_kind := CASE NEW.direction WHEN 'in' THEN 'income' ELSE 'expense' END::category_kind;
BEGIN
    -- the same transaction ID seen before (e.g. a bank SMS and its reminder): keep it, but as a duplicate
    IF NEW.reference IS NOT NULL THEN
        SELECT import_id INTO NEW.duplicate_of
        FROM imported_messages
        WHERE user_id = NEW.user_id AND provider = NEW.provider AND reference = NEW.reference
        ORDER BY import_id LIMIT 1;
        IF NEW.duplicate_of IS NOT NULL THEN
            NEW.status := 'duplicate';
        END IF;
    END IF;

    -- account: the one chosen last time for this provider, else an account named after it
    SELECT account_id INTO NEW.suggested_account_id
    FROM import_provider_accounts WHERE user_id = NEW.user_id AND provider = NEW.provider;
    IF NEW.suggested_account_id IS NULL THEN
        SELECT account_id INTO NEW.suggested_account_id
        FROM accounts
        WHERE user_id = NEW.user_id
          AND (account_name ILIKE NEW.provider || '%' OR NEW.provider ILIKE SPLIT_PART(account_name, ' ', 1) || '%')
        ORDER BY account_id LIMIT 1;
    END IF;

    -- category: the one chosen last time for this person or shop, else the hint (Food, Bills ...)
    IF NEW.counterparty IS NOT NULL THEN
        SELECT category_id INTO NEW.suggested_category_id
        FROM import_counterparty_categories
        WHERE user_id = NEW.user_id AND counterparty = LOWER(NEW.counterparty) AND direction = NEW.direction;
    END IF;
    IF NEW.suggested_category_id IS NULL AND NEW.category_hint IS NOT NULL THEN
        SELECT category_id INTO NEW.suggested_category_id
        FROM categories
        WHERE user_id = NEW.user_id AND type = v_kind AND LOWER(name) = LOWER(NEW.category_hint)
        LIMIT 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER imported_messages_prepare
BEFORE INSERT ON imported_messages
FOR EACH ROW EXECUTE FUNCTION trg_imported_message_prepare();

-- ---------------------------------------------------------------------
-- Add a message as a transaction (IM-04): once only, into the user's own account and category
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION add_imported_message(
    p_import_id   BIGINT,
    p_user_id     INT,
    p_account_id  INT,
    p_category_id INT,
    p_amount      NUMERIC DEFAULT NULL,      -- NULL = as read from the SMS
    p_txn_date    DATE    DEFAULT NULL,
    p_description VARCHAR DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    m      imported_messages%ROWTYPE;
    v_kind category_kind;
    v_txn  INT;
BEGIN
    -- the row lock makes two clicks (or two tabs) on "Add" wait for each other; the second then sees 'added'
    SELECT * INTO m FROM imported_messages WHERE import_id = p_import_id AND user_id = p_user_id FOR UPDATE;
    IF m.import_id IS NULL THEN
        RAISE EXCEPTION 'Message not found' USING ERRCODE = 'P0002';
    END IF;
    IF m.status = 'added' THEN
        RAISE EXCEPTION 'This message has already been added';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE account_id = p_account_id AND user_id = p_user_id) THEN
        RAISE EXCEPTION 'Choose one of your accounts';
    END IF;
    SELECT type INTO v_kind FROM categories WHERE category_id = p_category_id AND user_id = p_user_id;
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'Choose one of your categories';
    END IF;
    IF v_kind <> (CASE m.direction WHEN 'in' THEN 'income' ELSE 'expense' END)::category_kind THEN
        RAISE EXCEPTION 'Money % needs % category', CASE m.direction WHEN 'in' THEN 'coming in' ELSE 'going out' END,
                        CASE m.direction WHEN 'in' THEN 'an income' ELSE 'an expense' END;
    END IF;

    INSERT INTO transactions (account_id, category_id, amount, txn_date, description)
    VALUES (p_account_id, p_category_id, COALESCE(p_amount, m.amount), COALESCE(p_txn_date, m.txn_date),
            COALESCE(NULLIF(TRIM(p_description), ''), LEFT(m.provider || COALESCE(' · ' || m.counterparty, ''), 200)))
    RETURNING transaction_id INTO v_txn;

    UPDATE imported_messages SET status = 'added', transaction_id = v_txn, decided_at = NOW() WHERE import_id = p_import_id;

    -- remember for next time (IM-05)
    INSERT INTO import_provider_accounts (user_id, provider, account_id) VALUES (p_user_id, m.provider, p_account_id)
    ON CONFLICT (user_id, provider) DO UPDATE SET account_id = EXCLUDED.account_id;
    IF m.counterparty IS NOT NULL THEN
        INSERT INTO import_counterparty_categories (user_id, counterparty, direction, category_id)
        VALUES (p_user_id, LOWER(m.counterparty), m.direction, p_category_id)
        ON CONFLICT (user_id, counterparty, direction) DO UPDATE SET category_id = EXCLUDED.category_id;
    END IF;
    RETURN v_txn;
END;
$$;

-- ---------------------------------------------------------------------
-- Permissions for the website's account
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON sms_keys, imported_messages, import_provider_accounts, import_counterparty_categories TO fintrack_app;
GRANT USAGE, SELECT ON SEQUENCE imported_messages_import_id_seq TO fintrack_app;
GRANT EXECUTE ON FUNCTION add_imported_message(BIGINT, INT, INT, INT, NUMERIC, DATE, VARCHAR) TO fintrack_app;
