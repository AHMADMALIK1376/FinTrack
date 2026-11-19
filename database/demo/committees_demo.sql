-- =====================================================================
-- committees_demo.sql  -  sample committees for the demo user (demo@fintrack.pk)
--
-- Run after 04_seed.sql and 12_committees.sql, as the postgres user:
--   psql -U postgres -d fintrack -f database/demo/committees_demo.sql
-- It can be run again: it removes the sample committees and people it made before.
--
--   Family Committee   Rs 10,000 x 10, lucky draw, organized by Sara Malik. Round 3 (November) is being
--                      collected: six paid and confirmed, you have paid and wait for Sara, three are late.
--                      Your turn is round 7, March 2027.
--   Office BC          Rs 5,000 x 12, organized by Kamran Ali. You paid November on the 8th; your turn
--                      is round 6, January 2027.
--   Friends Eid BC     Rs 3,000 x 8, organized by Ayesha Khan, still getting ready: you are invited.
-- Everyone made here can log in with the password demo1234.
-- =====================================================================

DO $$
DECLARE
    v_demo   INT := (SELECT user_id FROM users WHERE email = 'demo@fintrack.pk');
    v_hash   TEXT := (SELECT password_hash FROM users WHERE email = 'demo@fintrack.pk');
    v_bank   INT;
    v_uid    INT;
    v_c      INT;
    v_m      INT;
    v_r      INT;
    v_ids    INT[];
    v_name   TEXT;
    i        INT;
    -- name, e-mail (NULL = guest, not on FinTrack)
    family   TEXT[][] := ARRAY[
        ['Sara Malik', 'sara.malik@demo.pk'], ['Usman Tariq', 'usman@demo.pk'], ['Ayesha Khan', 'ayesha@demo.pk'],
        ['Bilal Ahmed', 'bilal@demo.pk'], ['Hina (Phuppo)', NULL], ['Ali Raza', 'ali@demo.pk'], ['Demo User', 'demo@fintrack.pk'],
        ['Fatima Noor', 'fatima@demo.pk'], ['Khala Shabana', NULL], ['Zain Abbas', 'zain@demo.pk']];
    office   TEXT[][] := ARRAY[
        ['Kamran Ali', 'kamran@demo.pk'], ['Nadia Hussain', 'nadia@demo.pk'], ['Omar Farooq', 'omar@demo.pk'], ['Sana Iqbal', 'sana@demo.pk'],
        ['Hamza Sheikh', 'hamza@demo.pk'], ['Demo User', 'demo@fintrack.pk'], ['Rabia Aslam', 'rabia@demo.pk'], ['Faisal Mehmood', 'faisal@demo.pk'],
        ['Mehwish Ali', 'mehwish@demo.pk'], ['Tariq Jamil', 'tariq@demo.pk'], ['Asma Riaz', 'asma@demo.pk'], ['Imran Qureshi', 'imran@demo.pk']];
BEGIN
    IF v_demo IS NULL THEN
        RAISE EXCEPTION 'Run 04_seed.sql first: the demo user is missing';
    END IF;
    SELECT account_id INTO v_bank FROM accounts WHERE user_id = v_demo AND account_type = 'bank' ORDER BY account_id LIMIT 1;

    -- start again
    DELETE FROM committees WHERE name IN ('Family Committee', 'Office BC', 'Friends Eid BC')
       AND organizer_id IN (SELECT user_id FROM users WHERE email LIKE '%@demo.pk');
    DELETE FROM users WHERE email LIKE '%@demo.pk';

    -- the people
    FOR i IN 1 .. array_length(family, 1) LOOP
        IF family[i][2] IS NOT NULL AND family[i][2] LIKE '%@demo.pk' THEN
            INSERT INTO users (full_name, email, password_hash) VALUES (family[i][1], family[i][2], v_hash);
        END IF;
    END LOOP;
    FOR i IN 1 .. array_length(office, 1) LOOP
        IF office[i][2] LIKE '%@demo.pk' THEN
            INSERT INTO users (full_name, email, password_hash) VALUES (office[i][1], office[i][2], v_hash);
        END IF;
    END LOOP;
    INSERT INTO users (full_name, email, password_hash) VALUES ('Ayesha Khan', 'ayesha.friends@demo.pk', v_hash) ON CONFLICT DO NOTHING;

    -- 1. Family Committee: order 1 - 10 as listed, rounds 1 and 2 paid out
    INSERT INTO committees (name, organizer_id, amount, member_count, start_month, due_day, payout_day, payout_method, invite_code, status, order_set_at, created_at)
    VALUES ('Family Committee', (SELECT user_id FROM users WHERE email = 'sara.malik@demo.pk'), 10000, 10, '2026-09-01', 5, 10, 'draw',
            committee_invite_code('Family'), 'active', '2026-08-28 20:15', '2026-08-20 18:00')
    RETURNING committee_id INTO v_c;
    v_ids := '{}';
    FOR i IN 1 .. 10 LOOP
        INSERT INTO committee_members (committee_id, user_id, display_name, is_organizer, turn_no, link_account_id, joined_at)
        VALUES (v_c, (SELECT user_id FROM users WHERE email = family[i][2]), family[i][1], i = 1, i,
                CASE WHEN family[i][2] = 'demo@fintrack.pk' THEN v_bank END, '2026-08-20 18:00'::TIMESTAMPTZ + i * INTERVAL '3 hours')
        RETURNING member_id INTO v_m;
        v_ids := v_ids || v_m;
    END LOOP;
    FOR i IN 1 .. 10 LOOP
        INSERT INTO committee_rounds (committee_id, round_no, month, receiver_member_id)
        VALUES (v_c, i, ('2026-09-01'::DATE + make_interval(months => i - 1))::DATE, v_ids[i]);
    END LOOP;
    -- rounds 1 and 2: everyone paid, then paid out on the 10th
    FOR v_r IN SELECT round_id FROM committee_rounds WHERE committee_id = v_c AND round_no <= 2 LOOP
        INSERT INTO committee_payments (round_id, member_id, amount, marked_at, confirmed_at)
        SELECT v_r, m, 10000, r.month + 3, r.month + 4 FROM unnest(v_ids) m, committee_rounds r WHERE r.round_id = v_r;
        UPDATE committee_rounds SET paid_out_at = month + 9 + TIME '19:00' WHERE round_id = v_r;
    END LOOP;
    -- round 3 (November): six confirmed, you marked yours, Fatima, Khala and Zain not yet
    SELECT round_id INTO v_r FROM committee_rounds WHERE committee_id = v_c AND round_no = 3;
    INSERT INTO committee_payments (round_id, member_id, amount, marked_at, confirmed_at)
    SELECT v_r, v_ids[k], 10000, '2026-11-03 10:00'::TIMESTAMPTZ + k * INTERVAL '5 hours', '2026-11-05 21:00'::TIMESTAMPTZ + k * INTERVAL '1 hour'
    FROM generate_series(1, 6) k;
    INSERT INTO committee_payments (round_id, member_id, amount, marked_at) VALUES (v_r, v_ids[7], 10000, NOW() - INTERVAL '2 hours');
    INSERT INTO committee_events (committee_id, actor_id, message, created_at) VALUES
        (v_c, NULL, 'Sara Malik started the committee', '2026-08-20 18:00'),
        (v_c, NULL, 'Sara Malik drew the payout order', '2026-08-28 20:15'),
        (v_c, NULL, 'Sara Malik paid out Rs 100,000 to Sara Malik (round 1)', '2026-09-10 19:00'),
        (v_c, NULL, 'Sara Malik paid out Rs 100,000 to Usman Tariq (round 2)', '2026-10-10 19:00'),
        (v_c, NULL, 'Sara Malik recorded and confirmed Hina (Phuppo)''s payment', '2026-11-03 18:00'),
        (v_c, NULL, 'Sara Malik confirmed Ali Raza''s payment', NOW() - INTERVAL '1 day'),
        (v_c, v_demo, 'Demo User marked Rs 10,000 as paid', NOW() - INTERVAL '2 hours');

    -- 2. Office BC: you are 6th; rounds 1 - 3 paid out; November collected except two
    INSERT INTO committees (name, organizer_id, amount, member_count, start_month, due_day, payout_day, payout_method, invite_code, status, order_set_at, created_at)
    VALUES ('Office BC', (SELECT user_id FROM users WHERE email = 'kamran@demo.pk'), 5000, 12, '2026-08-01', 10, 15, 'fixed',
            committee_invite_code('Office'), 'active', '2026-07-25 13:00', '2026-07-20 13:00')
    RETURNING committee_id INTO v_c;
    v_ids := '{}';
    FOR i IN 1 .. 12 LOOP
        INSERT INTO committee_members (committee_id, user_id, display_name, is_organizer, turn_no)
        VALUES (v_c, (SELECT user_id FROM users WHERE email = office[i][2]), office[i][1], i = 1, i)
        RETURNING member_id INTO v_m;
        v_ids := v_ids || v_m;
        INSERT INTO committee_rounds (committee_id, round_no, month, receiver_member_id)
        VALUES (v_c, i, ('2026-08-01'::DATE + make_interval(months => i - 1))::DATE, v_m);
    END LOOP;
    FOR v_r IN SELECT round_id FROM committee_rounds WHERE committee_id = v_c AND round_no <= 3 LOOP
        INSERT INTO committee_payments (round_id, member_id, amount, marked_at, confirmed_at)
        SELECT v_r, m, 5000, r.month + 5, r.month + 7 FROM unnest(v_ids) m, committee_rounds r WHERE r.round_id = v_r;
        UPDATE committee_rounds SET paid_out_at = month + 14 + TIME '17:00' WHERE round_id = v_r;
    END LOOP;
    SELECT round_id INTO v_r FROM committee_rounds WHERE committee_id = v_c AND round_no = 4;
    INSERT INTO committee_payments (round_id, member_id, amount, marked_at, confirmed_at)
    SELECT v_r, v_ids[k], 5000, '2026-11-08 09:00'::TIMESTAMPTZ + k * INTERVAL '2 hours', '2026-11-09 12:00'
    FROM generate_series(1, 10) k;
    INSERT INTO committee_events (committee_id, actor_id, message, created_at) VALUES
        (v_c, NULL, 'Kamran Ali started the committee', '2026-07-20 13:00'),
        (v_c, NULL, 'Kamran Ali set the payout order', '2026-07-25 13:00'),
        (v_c, NULL, 'Kamran Ali paid out Rs 60,000 to Omar Farooq (round 3)', '2026-10-15 17:00');

    -- 3. Friends Eid BC: getting ready, 6 of 8 joined, you are invited
    INSERT INTO committees (name, organizer_id, amount, member_count, start_month, due_day, payout_day, payout_method, invite_code)
    VALUES ('Friends Eid BC', (SELECT user_id FROM users WHERE email = 'ayesha.friends@demo.pk'), 3000, 8, '2027-01-01', 5, 10, 'draw',
            committee_invite_code('Friends'))
    RETURNING committee_id INTO v_c;
    INSERT INTO committee_members (committee_id, user_id, display_name, is_organizer)
    VALUES (v_c, (SELECT user_id FROM users WHERE email = 'ayesha.friends@demo.pk'), 'Ayesha Khan', TRUE);
    FOREACH v_name IN ARRAY ARRAY['Mahnoor', 'Iqra', 'Hira', 'Anum', 'Sadia'] LOOP
        INSERT INTO committee_members (committee_id, display_name) VALUES (v_c, v_name);
    END LOOP;
    INSERT INTO committee_members (committee_id, user_id, display_name, status) VALUES (v_c, v_demo, 'Demo User', 'invited');
    INSERT INTO committee_events (committee_id, actor_id, message) VALUES (v_c, NULL, 'Ayesha Khan invited Demo User');

    RAISE NOTICE 'Sample committees ready. Log in as demo@fintrack.pk / demo1234 and open Committees.';
END
$$;
