-- =====================================================================
-- 12_committees.sql  -  Committees (BC): saving together in a group (BC-01 - BC-08)
--
-- A committee: N people each pay the same amount every month; each month
-- one of them receives the whole pot, until everyone has had one turn.
--
--   committees          the group: amount, number of people, start month, rules
--   committee_members   who is in it: FinTrack users (invited, asked to join, or
--                       approved) and guests (people not on FinTrack, by name)
--   committee_rounds    one row per month: who receives the pot, when it was paid out
--   committee_payments  who has paid in each round, and whether the organizer confirmed it
--   committee_events    what happened, in plain words (append-only, like audit_log)
--
-- The database itself guarantees the rules that keep a committee fair:
--   * never more approved members than places (trigger)
--   * every member has a different turn, and nobody receives the pot twice (UNIQUE)
--   * the lucky draw happens once, under a row lock, and can't be redone
--   * a round can't be paid out twice, or before everyone's payment is confirmed
--
-- Run as the postgres (admin) user, after 01 - 11. Running it again starts
-- with no committees.
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payout_kind') THEN
        -- draw: FinTrack draws the order once; fixed: the organizer sets it; organizer: chosen each month
        CREATE TYPE payout_kind AS ENUM ('draw', 'fixed', 'organizer');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'committee_status') THEN
        CREATE TYPE committee_status AS ENUM ('forming', 'active', 'finished');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'member_status') THEN
        -- invited: the organizer invited a FinTrack user; requested: someone asked to join with the code
        CREATE TYPE member_status AS ENUM ('invited', 'requested', 'approved');
    END IF;
END
$$;

DROP TABLE IF EXISTS committee_events, committee_payments, committee_rounds, committee_members, committees CASCADE;

CREATE TABLE committees (
    committee_id    SERIAL           PRIMARY KEY,
    name            VARCHAR(80)      NOT NULL CHECK (LENGTH(TRIM(name)) > 0),
    organizer_id    INT              NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    amount          money_pkr        NOT NULL CONSTRAINT chk_committee_amount CHECK (amount > 0),
    member_count    INT              NOT NULL CONSTRAINT chk_committee_size CHECK (member_count BETWEEN 2 AND 50),
    start_month     DATE             NOT NULL CONSTRAINT chk_committee_start_first CHECK (EXTRACT(DAY FROM start_month) = 1),
    due_day         SMALLINT         NOT NULL DEFAULT 5  CHECK (due_day BETWEEN 1 AND 28),
    payout_day      SMALLINT         NOT NULL DEFAULT 10 CHECK (payout_day BETWEEN 1 AND 28),
    payout_method   payout_kind      NOT NULL DEFAULT 'draw',
    invite_code     VARCHAR(9)       NOT NULL UNIQUE,
    status          committee_status NOT NULL DEFAULT 'forming',
    order_set_at    TIMESTAMPTZ,                         -- when the payout order was drawn or fixed (once)
    created_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

CREATE TABLE committee_members (
    member_id        SERIAL        PRIMARY KEY,
    committee_id     INT           NOT NULL REFERENCES committees(committee_id) ON DELETE CASCADE,
    user_id          INT           REFERENCES users(user_id) ON DELETE CASCADE,   -- NULL = guest (not on FinTrack)
    display_name     VARCHAR(100)  NOT NULL,
    is_organizer     BOOLEAN       NOT NULL DEFAULT FALSE,
    status           member_status NOT NULL DEFAULT 'approved',
    turn_no          INT,                                                         -- set when the order is drawn or fixed
    link_account_id  INT           REFERENCES accounts(account_id) ON DELETE SET NULL,  -- add my payments/payout here (BC-07)
    joined_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_committee_member_user UNIQUE (committee_id, user_id),
    CONSTRAINT uq_committee_member_turn UNIQUE (committee_id, turn_no),
    CONSTRAINT chk_member_turn CHECK (turn_no IS NULL OR turn_no >= 1),
    CONSTRAINT chk_guest_approved CHECK (user_id IS NOT NULL OR status = 'approved'),
    CONSTRAINT chk_guest_not_organizer CHECK (user_id IS NOT NULL OR NOT is_organizer)
);
CREATE INDEX idx_committee_members_user ON committee_members (user_id);

CREATE TABLE committee_rounds (
    round_id            SERIAL      PRIMARY KEY,
    committee_id        INT         NOT NULL REFERENCES committees(committee_id) ON DELETE CASCADE,
    round_no            INT         NOT NULL CHECK (round_no >= 1),
    month               DATE        NOT NULL,
    receiver_member_id  INT         REFERENCES committee_members(member_id),   -- NULL until chosen ('organizer' method)
    paid_out_at         TIMESTAMPTZ,
    CONSTRAINT uq_committee_round UNIQUE (committee_id, round_no),
    CONSTRAINT uq_committee_receiver UNIQUE (committee_id, receiver_member_id),  -- one turn each
    CONSTRAINT chk_paid_out_needs_receiver CHECK (paid_out_at IS NULL OR receiver_member_id IS NOT NULL)
);

CREATE TABLE committee_payments (
    payment_id    SERIAL       PRIMARY KEY,
    round_id      INT          NOT NULL REFERENCES committee_rounds(round_id) ON DELETE CASCADE,
    member_id     INT          NOT NULL REFERENCES committee_members(member_id) ON DELETE CASCADE,
    amount        money_pkr    NOT NULL CHECK (amount > 0),
    marked_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    marked_by     INT          REFERENCES users(user_id) ON DELETE SET NULL,
    confirmed_at  TIMESTAMPTZ,
    confirmed_by  INT          REFERENCES users(user_id) ON DELETE SET NULL,
    CONSTRAINT uq_round_member_payment UNIQUE (round_id, member_id)
);

-- what happened, in plain words; like audit_log it can only be added to
CREATE TABLE committee_events (
    event_id      BIGSERIAL    PRIMARY KEY,
    committee_id  INT          NOT NULL,          -- logical link, no FK: the history outlives a deleted committee
    actor_id      INT,                            -- who did it (NULL = FinTrack itself)
    message       TEXT         NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_committee_events ON committee_events (committee_id, created_at DESC);
CREATE TRIGGER committee_events_append_only
BEFORE UPDATE OR DELETE ON committee_events
FOR EACH ROW EXECUTE FUNCTION trg_audit_log_append_only();

COMMENT ON TABLE committees IS 'Committees (BC): N people pay the same amount each month; each month one receives the pot (BC-01).';

-- ---------------------------------------------------------------------
-- Rules enforced by triggers
-- ---------------------------------------------------------------------

-- never more approved members than places
CREATE OR REPLACE FUNCTION trg_committee_not_full()
RETURNS TRIGGER AS $$
DECLARE v_places INT; v_taken INT;
BEGIN
    IF NEW.status <> 'approved' THEN RETURN NEW; END IF;
    SELECT member_count INTO v_places FROM committees WHERE committee_id = NEW.committee_id FOR UPDATE;  -- one at a time
    SELECT COUNT(*) INTO v_taken FROM committee_members
     WHERE committee_id = NEW.committee_id AND status = 'approved' AND member_id IS DISTINCT FROM NEW.member_id;
    IF v_taken >= v_places THEN
        RAISE EXCEPTION 'This committee is full (% of % places taken)', v_taken, v_places;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER committee_members_not_full
BEFORE INSERT OR UPDATE OF status ON committee_members
FOR EACH ROW EXECUTE FUNCTION trg_committee_not_full();

-- a payout only when every member's payment for that round is confirmed, and only once
CREATE OR REPLACE FUNCTION trg_committee_payout_rules()
RETURNS TRIGGER AS $$
DECLARE v_missing INT;
BEGIN
    IF OLD.paid_out_at IS NOT NULL AND NEW.paid_out_at IS DISTINCT FROM OLD.paid_out_at THEN
        RAISE EXCEPTION 'This round has already been paid out';
    END IF;
    IF OLD.paid_out_at IS NULL AND NEW.paid_out_at IS NOT NULL THEN
        SELECT COUNT(*) INTO v_missing
        FROM committee_members m
        LEFT JOIN committee_payments p ON p.member_id = m.member_id AND p.round_id = NEW.round_id
        WHERE m.committee_id = NEW.committee_id AND m.status = 'approved' AND p.confirmed_at IS NULL;
        IF v_missing > 0 THEN
            RAISE EXCEPTION 'Not everyone has paid yet: % payment(s) still to be confirmed', v_missing;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER committee_rounds_payout_rules
BEFORE UPDATE ON committee_rounds
FOR EACH ROW EXECUTE FUNCTION trg_committee_payout_rules();

-- ---------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------

-- A short, easy-to-read invite code from the name, e.g. FAM-7K2Q (no 0/O or 1/I, which look alike)
CREATE OR REPLACE FUNCTION committee_invite_code(p_name TEXT)
RETURNS VARCHAR
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_letters CONSTANT TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    v_prefix  TEXT := RPAD(UPPER(LEFT(REGEXP_REPLACE(COALESCE(p_name, ''), '[^A-Za-z]', '', 'g'), 3)), 3, 'X');
    v_code    TEXT;
BEGIN
    LOOP
        v_code := v_prefix || '-' || (SELECT STRING_AGG(SUBSTR(v_letters, 1 + FLOOR(RANDOM() * LENGTH(v_letters))::INT, 1), '')
                                      FROM generate_series(1, 4));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM committees WHERE invite_code = v_code);
    END LOOP;
    RETURN v_code;
END;
$$;

-- Starts a committee once it is full: sets the payout order (once) and creates one round per month.
--   'draw'      FinTrack draws a random order now
--   'fixed'     p_order lists the member_ids in payout order (all approved members, each once)
--   'organizer' no order: the organizer chooses each round's receiver when paying out
CREATE OR REPLACE FUNCTION start_committee(p_committee_id INT, p_order INT[] DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    c        committees%ROWTYPE;
    v_count  INT;
BEGIN
    SELECT * INTO c FROM committees WHERE committee_id = p_committee_id FOR UPDATE;   -- nobody else starts or draws meanwhile
    IF c.committee_id IS NULL THEN RAISE EXCEPTION 'Committee not found'; END IF;
    IF c.status <> 'forming' OR c.order_set_at IS NOT NULL THEN
        RAISE EXCEPTION 'This committee has already started; its order can''t be changed';
    END IF;
    SELECT COUNT(*) INTO v_count FROM committee_members WHERE committee_id = p_committee_id AND status = 'approved';
    IF v_count <> c.member_count THEN
        RAISE EXCEPTION 'The committee needs % members to start; it has %', c.member_count, v_count;
    END IF;
    -- invitations nobody answered and requests nobody approved end here
    DELETE FROM committee_members WHERE committee_id = p_committee_id AND status <> 'approved';

    IF c.payout_method = 'draw' THEN
        UPDATE committee_members m SET turn_no = d.n
        FROM (SELECT member_id, ROW_NUMBER() OVER (ORDER BY RANDOM()) AS n
              FROM committee_members WHERE committee_id = p_committee_id AND status = 'approved') d
        WHERE m.member_id = d.member_id;
    ELSIF c.payout_method = 'fixed' THEN
        IF p_order IS NULL OR CARDINALITY(p_order) <> v_count
           OR (SELECT COUNT(DISTINCT x) FROM unnest(p_order) x) <> v_count
           OR EXISTS (SELECT 1 FROM unnest(p_order) x
                      WHERE x NOT IN (SELECT member_id FROM committee_members WHERE committee_id = p_committee_id AND status = 'approved')) THEN
            RAISE EXCEPTION 'Put every member in the payout order exactly once';
        END IF;
        UPDATE committee_members m SET turn_no = o.n
        FROM unnest(p_order) WITH ORDINALITY AS o(member_id, n)
        WHERE m.member_id = o.member_id;
    END IF;

    INSERT INTO committee_rounds (committee_id, round_no, month, receiver_member_id)
    SELECT p_committee_id, r, (c.start_month + make_interval(months => r - 1))::DATE,
           (SELECT member_id FROM committee_members WHERE committee_id = p_committee_id AND turn_no = r)
    FROM generate_series(1, c.member_count) r;

    UPDATE committees SET status = 'active', order_set_at = NOW() WHERE committee_id = p_committee_id;
END;
$$;

-- ---------------------------------------------------------------------
-- View: where each round stands (BC-06)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW committee_round_status AS
SELECT r.round_id, r.committee_id, r.round_no, r.month, r.receiver_member_id, r.paid_out_at,
       (SELECT COUNT(*) FROM committee_members m WHERE m.committee_id = r.committee_id AND m.status = 'approved')::INT AS members,
       COUNT(p.payment_id)::INT                                      AS marked_paid,
       COUNT(p.confirmed_at)::INT                                    AS confirmed,
       COALESCE(SUM(p.amount) FILTER (WHERE p.confirmed_at IS NOT NULL), 0)::NUMERIC AS collected
FROM committee_rounds r
LEFT JOIN committee_payments p ON p.round_id = r.round_id
GROUP BY r.round_id;

-- ---------------------------------------------------------------------
-- Permissions for the website's account
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON committees, committee_members, committee_rounds, committee_payments TO fintrack_app;
GRANT SELECT, INSERT ON committee_events TO fintrack_app;
GRANT SELECT ON committee_round_status TO fintrack_app;
GRANT USAGE, SELECT ON SEQUENCE committees_committee_id_seq, committee_members_member_id_seq,
      committee_rounds_round_id_seq, committee_payments_payment_id_seq, committee_events_event_id_seq TO fintrack_app;
GRANT EXECUTE ON FUNCTION committee_invite_code(TEXT), start_committee(INT, INT[]) TO fintrack_app;
