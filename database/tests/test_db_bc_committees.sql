-- BC-01 - BC-05: committees (12_committees.sql): places, turns, the one-time draw, fixed order, payouts.
BEGIN;

-- expect_error(sql, sqlstates, rule): passes only if the statement fails with one of the error codes
CREATE FUNCTION pg_temp.expect_error(p_sql TEXT, p_state TEXT, p_rule TEXT) RETURNS VOID AS $fn$
DECLARE failed BOOLEAN := FALSE;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF NOT (SQLSTATE = ANY (string_to_array(p_state, ','))) THEN
            RAISE EXCEPTION '% expected error % but got % (%) for: %', p_rule, p_state, SQLSTATE, SQLERRM, p_sql;
        END IF;
        failed := TRUE;
    END;
    IF NOT failed THEN
        RAISE EXCEPTION '% expected error % but the statement succeeded: %', p_rule, p_state, p_sql;
    END IF;
    RAISE NOTICE 'PASS %', p_rule;
END;
$fn$ LANGUAGE plpgsql;

DO $$
DECLARE
    u INT[] := '{}'; uid INT; c INT; c2 INT; m INT[] := '{}'; mid INT; guest INT; r1 INT; code TEXT; turns INT[]; i INT; o1 INT; o2 INT;
BEGIN
    FOR i IN 1..4 LOOP
        INSERT INTO users (full_name, email, password_hash) VALUES ('BC ' || i, 'bc' || i || '@test.pk', 'x') RETURNING user_id INTO uid;
        u := u || uid;
    END LOOP;

    -- BC-01 a committee of 3 at Rs 1,000, lucky draw
    code := committee_invite_code('Family Committee');
    ASSERT code ~ '^FAM-[A-HJ-NP-Z2-9]{4}$', 'BC-02 invite code looks like FAM-7K2Q, got ' || code;
    RAISE NOTICE 'PASS BC-02 invite codes look like FAM-7K2Q (no 0/O or 1/I)';
    INSERT INTO committees (name, organizer_id, amount, member_count, start_month, payout_method, invite_code)
    VALUES ('Family Committee', u[1], 1000, 3, '2026-09-01', 'draw', code) RETURNING committee_id INTO c;
    INSERT INTO committee_members (committee_id, user_id, display_name, is_organizer) VALUES (c, u[1], 'BC 1', TRUE) RETURNING member_id INTO mid; m := m || mid;
    INSERT INTO committee_members (committee_id, user_id, display_name) VALUES (c, u[2], 'BC 2') RETURNING member_id INTO mid; m := m || mid;
    INSERT INTO committee_members (committee_id, user_id, display_name, status) VALUES (c, u[3], 'BC 3', 'requested') RETURNING member_id INTO mid;
    INSERT INTO committee_members (committee_id, display_name) VALUES (c, 'Khala (guest)') RETURNING member_id INTO guest; m := m || guest;

    PERFORM pg_temp.expect_error(format('UPDATE committee_members SET status = %L WHERE member_id = %s', 'approved', mid), 'P0001',
                                 'BC-01 a full committee refuses one more member');
    PERFORM pg_temp.expect_error(format('INSERT INTO committee_members (committee_id, user_id, display_name, status) VALUES (%s, %s, %L, %L)', c, u[2], 'again', 'requested'), '23505',
                                 'BC-02 the same person can''t join twice');
    PERFORM pg_temp.expect_error(format('INSERT INTO committee_members (committee_id, display_name, status) VALUES (%s, %L, %L)', c, 'x', 'requested'), '23514',
                                 'BC-02 a guest is always approved (they have no account to ask from)');
    PERFORM pg_temp.expect_error(format('INSERT INTO committees (name, organizer_id, amount, member_count, start_month, invite_code) VALUES (%L, %s, 0, 3, %L, %L)', 'x', u[1], '2026-09-01', 'ZZZ-2222'), '23514',
                                 'BC-01 the amount must be above zero');
    PERFORM pg_temp.expect_error(format('INSERT INTO committees (name, organizer_id, amount, member_count, start_month, invite_code) VALUES (%L, %s, 100, 3, %L, %L)', 'x', u[1], '2026-09-15', 'ZZZ-3333'), '23514',
                                 'BC-01 a committee starts on the 1st of a month');

    -- BC-03 the draw: every member gets a different turn, once
    PERFORM start_committee(c);
    SELECT array_agg(turn_no ORDER BY turn_no) INTO turns FROM committee_members WHERE committee_id = c AND status = 'approved';
    ASSERT turns = ARRAY[1, 2, 3], 'BC-03 the draw gives turns 1, 2, 3, got ' || turns::TEXT;
    ASSERT (SELECT array_agg(month ORDER BY round_no) FROM committee_rounds WHERE committee_id = c) = ARRAY['2026-09-01', '2026-10-01', '2026-11-01']::DATE[],
           'BC-03 one round per month from the start month';
    ASSERT (SELECT COUNT(DISTINCT receiver_member_id) FROM committee_rounds WHERE committee_id = c) = 3, 'BC-03 each member receives once';
    ASSERT (SELECT status FROM committees WHERE committee_id = c) = 'active', 'BC-03 the committee is active after starting';
    RAISE NOTICE 'PASS BC-03 the lucky draw gives every member one different turn and creates one round per month';
    PERFORM pg_temp.expect_error(format('SELECT start_committee(%s)', c), 'P0001', 'BC-03 the draw can''t be redone');
    PERFORM pg_temp.expect_error(format('UPDATE committee_rounds SET receiver_member_id = (SELECT receiver_member_id FROM committee_rounds WHERE committee_id = %s AND round_no = 1) WHERE committee_id = %s AND round_no = 2', c, c), '23505',
                                 'BC-03 nobody can receive the pot twice');

    -- BC-04 payouts only when everyone's payment is confirmed, and only once
    SELECT round_id INTO r1 FROM committee_rounds WHERE committee_id = c AND round_no = 1;
    INSERT INTO committee_payments (round_id, member_id, amount, marked_by, confirmed_at, confirmed_by) VALUES (r1, m[1], 1000, u[1], NOW(), u[1]);
    INSERT INTO committee_payments (round_id, member_id, amount, marked_by) VALUES (r1, m[2], 1000, u[2]);   -- marked, not confirmed
    PERFORM pg_temp.expect_error(format('UPDATE committee_rounds SET paid_out_at = NOW() WHERE round_id = %s', r1), 'P0001',
                                 'BC-04 no payout while payments are missing or unconfirmed');
    PERFORM pg_temp.expect_error(format('INSERT INTO committee_payments (round_id, member_id, amount) VALUES (%s, %s, 1000)', r1, m[2]), '23505',
                                 'BC-04 a member pays once per round');
    UPDATE committee_payments SET confirmed_at = NOW(), confirmed_by = u[1] WHERE round_id = r1 AND member_id = m[2];
    INSERT INTO committee_payments (round_id, member_id, amount, marked_by, confirmed_at, confirmed_by) VALUES (r1, guest, 1000, u[1], NOW(), u[1]);
    ASSERT (SELECT (marked_paid, confirmed, collected) FROM committee_round_status WHERE round_id = r1) = (3, 3, 3000::NUMERIC),
           'BC-06 the round status view counts 3 confirmed and Rs 3,000 collected';
    RAISE NOTICE 'PASS BC-06 committee_round_status counts payments and money collected';
    UPDATE committee_rounds SET paid_out_at = NOW() WHERE round_id = r1;
    RAISE NOTICE 'PASS BC-04 a round is paid out once every payment is confirmed';
    PERFORM pg_temp.expect_error(format('UPDATE committee_rounds SET paid_out_at = NOW() + INTERVAL %L WHERE round_id = %s', '1 hour', r1), 'P0001',
                                 'BC-04 a round can''t be paid out twice');

    -- BC-03 fixed order: every approved member exactly once
    INSERT INTO committees (name, organizer_id, amount, member_count, start_month, payout_method, invite_code)
    VALUES ('Office BC', u[1], 500, 2, '2026-12-01', 'fixed', committee_invite_code('Office BC')) RETURNING committee_id INTO c2;
    INSERT INTO committee_members (committee_id, user_id, display_name, is_organizer) VALUES (c2, u[1], 'BC 1', TRUE) RETURNING member_id INTO o1;
    INSERT INTO committee_members (committee_id, user_id, display_name) VALUES (c2, u[4], 'BC 4') RETURNING member_id INTO o2;
    PERFORM pg_temp.expect_error(format('SELECT start_committee(%s, ARRAY[%s, %s])', c2, o1, o1), 'P0001', 'BC-03 a fixed order lists each member once');
    PERFORM start_committee(c2, ARRAY[o2, o1]);
    ASSERT (SELECT turn_no FROM committee_members WHERE member_id = o2) = 1, 'BC-03 a fixed order is used as given';
    RAISE NOTICE 'PASS BC-03 a fixed order must list every member once, and is used as given';

    -- events can only be added
    INSERT INTO committee_events (committee_id, actor_id, message) VALUES (c, u[1], 'test');
    PERFORM pg_temp.expect_error('UPDATE committee_events SET message = ''changed''', 'P0001', 'BC-04 the committee history can''t be changed');
    PERFORM pg_temp.expect_error('DELETE FROM committee_events', 'P0001', 'BC-04 the committee history can''t be deleted');
END
$$;

ROLLBACK;
