<?php
/**
 * Committees (BC-01 - BC-08): saving together. Everyone pays the same amount each month,
 * and each month one member receives the whole pot.
 *
 * Who can do what:
 *   - anyone logged in: start a committee, look up a code, ask to join
 *   - members: see the committee, mark their own payment as paid, link an account
 *   - the organizer only: invite, add guests, approve, start, confirm payments, pay out
 * Someone who is not a member gets "Committee not found", so codes and ids reveal nothing (SEC-01).
 * The fairness rules (places, turns, one draw, payouts) are enforced by the database (12_committees.sql).
 */
declare(strict_types=1);

/** The committee with the user's own membership, or a 404 if they are not in it. */
function committee_for(int $userId, int $committeeId): array
{
    $row = query_one(
        'SELECT c.*, u.full_name AS organizer_name, me.member_id AS my_member_id, me.status AS my_status,
                me.is_organizer AS i_organize, me.display_name AS my_name, me.turn_no AS my_turn, me.link_account_id
         FROM committees c
         JOIN users u              ON u.user_id = c.organizer_id
         JOIN committee_members me ON me.committee_id = c.committee_id AND me.user_id = ?
         WHERE c.committee_id = ?', [$userId, $committeeId]);
    if ($row === null) {
        throw new ApiError(404, 'Committee not found.');
    }
    return $row;
}

function require_organizer(array $committee): void
{
    if (!$committee['i_organize']) {
        throw new ApiError(403, 'Only the organizer can do this.');
    }
}

function require_forming(array $committee, string $what): void
{
    if ($committee['status'] !== 'forming') {
        throw new ApiError(400, "The committee has started, so $what.");
    }
}

/** Adds a line to the committee's history (append-only in the database). */
function committee_event(int $committeeId, ?int $actorId, string $message): void
{
    execute('INSERT INTO committee_events (committee_id, actor_id, message) VALUES (?, ?, ?)', [$committeeId, $actorId, $message]);
}

/** The member's "Committee" category of the given type, created the first time (like "Transfer"). */
function committee_category(int $userId, string $type): int
{
    execute("INSERT INTO categories (user_id, name, type) VALUES (?, 'Committee', ?) ON CONFLICT (user_id, name, type) DO NOTHING",
        [$userId, $type]);
    return (int) query_one("SELECT category_id FROM categories WHERE user_id = ? AND name = 'Committee' AND type = ?",
        [$userId, $type])['category_id'];
}

/**
 * BC-07: when a member has linked an account, their payment (expense) or payout (income)
 * is also added to their FinTrack transactions, so balances and reports include it.
 */
function committee_transaction(array $member, string $type, mixed $amount, string $description): void
{
    if ($member['user_id'] === null || $member['link_account_id'] === null) {
        return;
    }
    execute('INSERT INTO transactions (account_id, category_id, amount, txn_date, description) VALUES (?, ?, ?, CURRENT_DATE, ?)',
        [$member['link_account_id'], committee_category((int) $member['user_id'], $type), $amount, $description]);
}

/** A member of this committee, or a 404. */
function committee_member(int $committeeId, mixed $memberId): array
{
    $member = query_one('SELECT * FROM committee_members WHERE member_id = ? AND committee_id = ?', [$memberId, $committeeId]);
    if ($member === null) {
        throw new ApiError(404, 'Member not found.');
    }
    return $member;
}

/** The round being collected now: the first one not yet paid out. Payments are only taken for it. */
function current_round(array $committee, int $roundId): array
{
    if ($committee['status'] !== 'active') {
        throw new ApiError(400, $committee['status'] === 'forming' ? 'The committee hasn\'t started yet.' : 'This committee has finished.');
    }
    $round = query_one(
        'SELECT * FROM committee_rounds WHERE committee_id = ? AND paid_out_at IS NULL ORDER BY round_no LIMIT 1',
        [$committee['committee_id']]);
    if ($round === null || (int) $round['round_id'] !== $roundId) {
        throw new ApiError(400, 'Payments can only be made for the current round.');
    }
    return $round;
}

/**
 * GET /api/committees: the user's committees and invitations, with where each one stands for them.
 */
function committees_list(array $user): void
{
    json_response(query(
        "SELECT c.committee_id, c.name, c.amount, c.member_count, c.start_month, c.due_day, c.payout_day, c.payout_method,
                c.status, c.invite_code, u.full_name AS organizer_name,
                me.member_id, me.status AS my_status, me.is_organizer, me.turn_no AS my_turn,
                (SELECT COUNT(*) FROM committee_members x WHERE x.committee_id = c.committee_id AND x.status = 'approved')::INT AS approved_count,
                (SELECT COUNT(*) FROM committee_rounds x WHERE x.committee_id = c.committee_id AND x.paid_out_at IS NOT NULL)::INT AS rounds_done,
                CASE WHEN me.is_organizer THEN (SELECT COUNT(*) FROM committee_members x
                     WHERE x.committee_id = c.committee_id AND x.status = 'requested') ELSE 0 END::INT AS requests,
                cur.round_id AS current_round_id, cur.round_no AS current_round, cur.month AS current_month,
                rm.display_name AS current_receiver, (rm.member_id = me.member_id) AS i_receive_now,
                mp.marked_at AS my_marked_at, mp.confirmed_at AS my_confirmed_at,
                (SELECT COALESCE(SUM(p.amount), 0) FROM committee_payments p WHERE p.member_id = me.member_id) AS my_paid_in,
                mine.month AS my_payout_month, mine.paid_out_at AS my_paid_out_at
         FROM committee_members me
         JOIN committees c ON c.committee_id = me.committee_id
         JOIN users u      ON u.user_id = c.organizer_id
         LEFT JOIN LATERAL (SELECT * FROM committee_rounds r WHERE r.committee_id = c.committee_id AND r.paid_out_at IS NULL
                            ORDER BY r.round_no LIMIT 1) cur ON TRUE
         LEFT JOIN committee_members rm  ON rm.member_id = cur.receiver_member_id
         LEFT JOIN committee_payments mp ON mp.round_id = cur.round_id AND mp.member_id = me.member_id
         LEFT JOIN committee_rounds mine ON mine.committee_id = c.committee_id AND mine.receiver_member_id = me.member_id
         WHERE me.user_id = ?
         ORDER BY CASE c.status WHEN 'active' THEN 0 WHEN 'forming' THEN 1 ELSE 2 END, c.created_at DESC",
        [$user['id']]));
}

/**
 * POST /api/committees  { name, amount, member_count, start_month: "2026-12", due_day?, payout_day?, payout_method? }
 * The creator becomes the organizer and the first member (BC-01).
 */
function committees_create(array $user): void
{
    $body = request_body();
    $name = trim((string) field($body, 'name'));
    if ($name === '') {
        throw new ApiError(400, 'Give the committee a name.');
    }
    $month = (string) field($body, 'start_month');
    if (!preg_match('/^\d{4}-\d{2}$/', $month)) {
        throw new ApiError(400, 'Choose the first month.');
    }
    $row = in_transaction($user['id'], function () use ($user, $body, $name, $month) {
        $committee = query_one(
            'INSERT INTO committees (name, organizer_id, amount, member_count, start_month, due_day, payout_day, payout_method, invite_code)
             VALUES (?, ?, ?, ?, CAST(? AS date), ?, ?, ?, committee_invite_code(?)) RETURNING *',
            [$name, $user['id'], field($body, 'amount'), field($body, 'member_count'), "$month-01",
             field($body, 'due_day') ?? 5, field($body, 'payout_day') ?? 10, field($body, 'payout_method') ?? 'draw', $name]);
        execute('INSERT INTO committee_members (committee_id, user_id, display_name, is_organizer) VALUES (?, ?, ?, TRUE)',
            [$committee['committee_id'], $user['id'], $user['name']]);
        committee_event((int) $committee['committee_id'], $user['id'], "{$user['name']} started the committee");
        return $committee;
    });
    json_response($row, 201);
}

/**
 * GET /api/committees/{id}: everything a member sees. People who are only invited or asked to join
 * see the basics and who has joined, not payments or history.
 */
function committees_get(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    $approved = $c['my_status'] === 'approved';
    $members = query(
        'SELECT member_id, display_name, (user_id IS NULL) AS is_guest, is_organizer, status, turn_no, (user_id = ?) AS is_me
         FROM committee_members WHERE committee_id = ?' . ($approved ? '' : " AND status = 'approved'") . '
         ORDER BY turn_no NULLS LAST, is_organizer DESC, member_id', [$user['id'], $id]);
    $rounds = [];
    $events = [];
    if ($approved) {
        $rounds = query(
            'SELECT s.*, m.display_name AS receiver_name FROM committee_round_status s
             LEFT JOIN committee_members m ON m.member_id = s.receiver_member_id
             WHERE s.committee_id = ? ORDER BY s.round_no', [$id]);
        $payments = query(
            'SELECT p.round_id, p.member_id, p.amount, p.marked_at, p.confirmed_at FROM committee_payments p
             JOIN committee_rounds r ON r.round_id = p.round_id WHERE r.committee_id = ?', [$id]);
        foreach ($rounds as &$round) {
            $round['payments'] = array_values(array_filter($payments, fn ($p) => $p['round_id'] === $round['round_id']));
        }
        unset($round);
        $events = query('SELECT message, created_at FROM committee_events WHERE committee_id = ? ORDER BY event_id DESC LIMIT 30', [$id]);
    }
    $committee = array_diff_key($c, array_flip(['my_member_id', 'my_status', 'i_organize', 'my_name', 'my_turn', 'link_account_id']));
    if (!$approved) {
        unset($committee['invite_code']);
    }
    json_response([
        'committee' => $committee,
        'me' => ['member_id' => $c['my_member_id'], 'status' => $c['my_status'], 'is_organizer' => $c['i_organize'],
                 'turn_no' => $c['my_turn'], 'link_account_id' => $c['link_account_id']],
        'members' => $members,
        'rounds' => $rounds,
        'events' => $events,
    ]);
}

/** DELETE /api/committees/{id}: the organizer can cancel a committee that hasn't started. */
function committees_delete(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    require_forming($c, 'it can\'t be deleted');
    execute_as_user($user['id'], 'DELETE FROM committees WHERE committee_id = ?', [$id]);
    no_content();
}

/** GET /api/committees/code?code=FAM-7K2Q: a short preview before joining (BC-02). */
function committees_find_code(array $user): void
{
    $row = query_one(
        "SELECT c.committee_id, c.name, c.amount, c.member_count, c.start_month, c.payout_method, c.status,
                u.full_name AS organizer_name,
                (SELECT COUNT(*) FROM committee_members m WHERE m.committee_id = c.committee_id AND m.status = 'approved')::INT AS approved_count,
                (SELECT status FROM committee_members m WHERE m.committee_id = c.committee_id AND m.user_id = ?) AS my_status
         FROM committees c JOIN users u ON u.user_id = c.organizer_id
         WHERE c.invite_code = UPPER(TRIM(?))", [$user['id'], (string) query_param('code')]);
    if ($row === null) {
        throw new ApiError(404, 'No committee has that code. Check it with the organizer.');
    }
    json_response($row);
}

/**
 * POST /api/committees/join  { code }: ask to join; the organizer approves (BC-02).
 * If the organizer already invited this user, joining accepts the invitation straight away.
 */
function committees_join(array $user): void
{
    $code = strtoupper(trim((string) field(request_body(), 'code')));
    $c = query_one('SELECT committee_id, name, status FROM committees WHERE invite_code = ?', [$code]);
    if ($c === null) {
        throw new ApiError(404, 'No committee has that code. Check it with the organizer.');
    }
    if ($c['status'] !== 'forming') {
        throw new ApiError(400, 'This committee has already started, so it can\'t take new members.');
    }
    $id = (int) $c['committee_id'];
    $result = in_transaction($user['id'], function () use ($user, $id) {
        $mine = query_one('SELECT status FROM committee_members WHERE committee_id = ? AND user_id = ?', [$id, $user['id']]);
        if ($mine !== null && $mine['status'] !== 'invited') {
            throw new ApiError(409, $mine['status'] === 'approved' ? 'You are already in this committee.' : 'You have already asked to join. The organizer will approve you.');
        }
        if ($mine !== null) {
            execute("UPDATE committee_members SET status = 'approved', joined_at = NOW() WHERE committee_id = ? AND user_id = ?", [$id, $user['id']]);
            committee_event($id, $user['id'], "{$user['name']} joined");
            return 'approved';
        }
        execute("INSERT INTO committee_members (committee_id, user_id, display_name, status) VALUES (?, ?, ?, 'requested')",
            [$id, $user['id'], $user['name']]);
        committee_event($id, $user['id'], "{$user['name']} asked to join");
        return 'requested';
    });
    json_response(['committee_id' => $id, 'name' => $c['name'], 'status' => $result], 201);
}

/** POST /api/committees/{id}/accept: accept an invitation. */
function committees_accept(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    if ($c['my_status'] !== 'invited') {
        throw new ApiError(400, 'There is no invitation to accept.');
    }
    require_forming($c, 'it can\'t take new members');
    in_transaction($user['id'], function () use ($c, $user, $id) {
        execute("UPDATE committee_members SET status = 'approved', joined_at = NOW() WHERE member_id = ?", [$c['my_member_id']]);
        committee_event($id, $user['id'], "{$c['my_name']} accepted the invitation");
    });
    no_content();
}

/** POST /api/committees/{id}/invite  { email }: the organizer invites someone who is on FinTrack. */
function committees_invite(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    require_forming($c, 'it can\'t take new members');
    $email = trim((string) field(request_body(), 'email'));
    $person = query_one('SELECT user_id, full_name FROM users WHERE LOWER(email) = LOWER(?)', [$email]);
    if ($person === null) {
        throw new ApiError(404, 'Nobody on FinTrack uses that e-mail. Send them the WhatsApp link, or add them as a guest.');
    }
    if (query_one('SELECT 1 AS x FROM committee_members WHERE committee_id = ? AND user_id = ?', [$id, $person['user_id']]) !== null) {
        throw new ApiError(409, "{$person['full_name']} is already in this committee or invited.");
    }
    $row = in_transaction($user['id'], function () use ($id, $person, $user) {
        $member = query_one("INSERT INTO committee_members (committee_id, user_id, display_name, status) VALUES (?, ?, ?, 'invited')
                             RETURNING member_id, display_name, status", [$id, $person['user_id'], $person['full_name']]);
        committee_event($id, $user['id'], "{$user['name']} invited {$person['full_name']}");
        return $member;
    });
    json_response($row, 201);
}

/** POST /api/committees/{id}/guests  { display_name }: someone not on FinTrack; the organizer records their payments (BC-05). */
function committees_add_guest(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    require_forming($c, 'it can\'t take new members');
    $name = trim((string) field(request_body(), 'display_name'));
    if ($name === '') {
        throw new ApiError(400, 'Type the guest\'s name.');
    }
    $row = in_transaction($user['id'], function () use ($id, $name, $user) {
        $member = query_one('INSERT INTO committee_members (committee_id, display_name) VALUES (?, ?) RETURNING member_id, display_name, status',
            [$id, $name]);
        committee_event($id, $user['id'], "{$user['name']} added $name as a guest");
        return $member;
    });
    json_response($row, 201);
}

/** POST /api/committees/{id}/members/{member}/approve: the organizer lets someone in who asked to join. */
function committees_approve(array $user, int $id, int $memberId): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    require_forming($c, 'it can\'t take new members');
    $member = committee_member($id, $memberId);
    if ($member['status'] !== 'requested') {
        throw new ApiError(400, 'Only people who asked to join can be approved.');
    }
    in_transaction($user['id'], function () use ($id, $member, $user) {
        execute("UPDATE committee_members SET status = 'approved', joined_at = NOW() WHERE member_id = ?", [$member['member_id']]);
        committee_event($id, $user['id'], "{$user['name']} approved {$member['display_name']}");
    });
    no_content();
}

/**
 * DELETE /api/committees/{id}/members/{member}: before the start, the organizer can remove anyone else,
 * and anyone can leave, cancel their request or say no to an invitation.
 */
function committees_remove_member(array $user, int $id, int $memberId): void
{
    $c = committee_for($user['id'], $id);
    $member = committee_member($id, $memberId);
    $self = (int) $member['member_id'] === (int) $c['my_member_id'];
    if (!$self && !$c['i_organize']) {
        throw new ApiError(403, 'Only the organizer can do this.');
    }
    if ($member['is_organizer']) {
        throw new ApiError(400, 'The organizer can\'t leave. Delete the committee instead.');
    }
    require_forming($c, 'members can\'t leave or be removed');
    in_transaction($user['id'], function () use ($id, $member, $user, $self) {
        execute('DELETE FROM committee_members WHERE member_id = ?', [$member['member_id']]);
        $what = match (true) {
            $self && $member['status'] === 'invited' => "{$member['display_name']} said no to the invitation",
            $self => "{$member['display_name']} left",
            default => "{$user['name']} removed {$member['display_name']}",
        };
        committee_event($id, $user['id'], $what);
    });
    no_content();
}

/**
 * POST /api/committees/{id}/start  { order?: [member_id, ...] }: once every place is filled,
 * the organizer starts: the order is drawn (or taken as given) once, and the rounds are created (BC-03).
 */
function committees_start(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    $order = request_body()['order'] ?? null;
    if ($order !== null && (!is_array($order) || array_filter($order, fn ($x) => !is_int($x)) !== [])) {
        throw new ApiError(400, 'A value has the wrong format.');
    }
    in_transaction($user['id'], function () use ($id, $order, $user, $c) {
        query('SELECT start_committee(?, CAST(? AS int[]))', [$id, $order === null ? null : '{' . implode(',', $order) . '}']);
        $how = ['draw' => 'drew the payout order', 'fixed' => 'set the payout order', 'organizer' => 'started the committee'][$c['payout_method']];
        committee_event($id, $user['id'], "{$user['name']} $how");
    });
    committees_get($user, $id);
}

/** PUT /api/committees/{id}/link  { account_id | null }: add my payments and payout to this account (BC-07). */
function committees_link(array $user, int $id): void
{
    $c = committee_for($user['id'], $id);
    $accountId = field(request_body(), 'account_id');
    if ($accountId !== null && query_one('SELECT 1 AS x FROM accounts WHERE account_id = ? AND user_id = ?', [$accountId, $user['id']]) === null) {
        throw new ApiError(404, 'Account not found.');
    }
    execute('UPDATE committee_members SET link_account_id = ? WHERE member_id = ?', [$accountId, $c['my_member_id']]);
    no_content();
}

/** POST /api/committees/{id}/rounds/{round}/paid: "I've paid" for the current round; the organizer confirms later (BC-04). */
function committees_mark_paid(array $user, int $id, int $roundId): void
{
    $c = committee_for($user['id'], $id);
    if ($c['my_status'] !== 'approved') {
        throw new ApiError(404, 'Committee not found.');
    }
    $round = current_round($c, $roundId);
    $me = committee_member($id, $c['my_member_id']);
    try {
        in_transaction($user['id'], function () use ($c, $me, $round, $user, $id) {
            execute('INSERT INTO committee_payments (round_id, member_id, amount, marked_by) VALUES (?, ?, ?, ?)',
                [$round['round_id'], $me['member_id'], $c['amount'], $user['id']]);
            committee_transaction($me, 'expense', $c['amount'], "{$c['name']} · round {$round['round_no']}");
            committee_event($id, $user['id'], "{$me['display_name']} marked " . rupees($c['amount']) . ' as paid');
        });
    }
    catch (PDOException $error) {
        if (($error->errorInfo[0] ?? '') === '23505') {
            throw new ApiError(409, 'You have already marked this round as paid.');
        }
        throw $error;
    }
    no_content();
}

/**
 * POST /api/committees/{id}/rounds/{round}/confirm  { member_id }: the organizer confirms a payment.
 * For a guest, or someone who paid in cash without marking it, this records and confirms it in one step.
 */
function committees_confirm(array $user, int $id, int $roundId): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    $round = current_round($c, $roundId);
    $member = committee_member($id, field(request_body(), 'member_id'));
    if ($member['status'] !== 'approved') {
        throw new ApiError(400, 'Only members of the committee pay in.');
    }
    in_transaction($user['id'], function () use ($c, $member, $round, $user, $id) {
        $payment = query_one('SELECT * FROM committee_payments WHERE round_id = ? AND member_id = ? FOR UPDATE',
            [$round['round_id'], $member['member_id']]);
        if ($payment !== null && $payment['confirmed_at'] !== null) {
            throw new ApiError(409, "{$member['display_name']}'s payment is already confirmed.");
        }
        if ($payment === null) {
            execute('INSERT INTO committee_payments (round_id, member_id, amount, marked_by, confirmed_at, confirmed_by) VALUES (?, ?, ?, ?, NOW(), ?)',
                [$round['round_id'], $member['member_id'], $c['amount'], $user['id'], $user['id']]);
            committee_transaction($member, 'expense', $c['amount'], "{$c['name']} · round {$round['round_no']}");
            committee_event($id, $user['id'], "{$user['name']} recorded and confirmed {$member['display_name']}'s payment");
        }
        else {
            execute('UPDATE committee_payments SET confirmed_at = NOW(), confirmed_by = ? WHERE payment_id = ?', [$user['id'], $payment['payment_id']]);
            committee_event($id, $user['id'], "{$user['name']} confirmed {$member['display_name']}'s payment");
        }
    });
    no_content();
}

/**
 * POST /api/committees/{id}/rounds/{round}/payout  { receiver_member_id? }: the organizer pays out the pot.
 * The database refuses it until every payment is confirmed, and never twice (BC-04). With the
 * "organizer chooses" method the receiver is picked here; they can't have had a turn already.
 */
function committees_payout(array $user, int $id, int $roundId): void
{
    $c = committee_for($user['id'], $id);
    require_organizer($c);
    $round = current_round($c, $roundId);
    $receiverId = $round['receiver_member_id'] ?? field(request_body(), 'receiver_member_id');
    if ($receiverId === null) {
        throw new ApiError(400, 'Choose who gets the pot this round.');
    }
    $receiver = committee_member($id, $receiverId);
    if ($receiver['status'] !== 'approved') {
        throw new ApiError(400, 'Only members of the committee can get the pot.');
    }
    try {
        in_transaction($user['id'], function () use ($c, $round, $receiver, $user, $id) {
            execute('UPDATE committee_rounds SET receiver_member_id = ?, paid_out_at = NOW() WHERE round_id = ?',
                [$receiver['member_id'], $round['round_id']]);
            $pot = (float) $c['amount'] * (int) $c['member_count'];
            committee_transaction($receiver, 'income', $pot, "{$c['name']} · my turn (round {$round['round_no']})");
            committee_event($id, $user['id'], "{$user['name']} paid out " . rupees($pot) . " to {$receiver['display_name']} (round {$round['round_no']})");
            if ((int) $round['round_no'] === (int) $c['member_count']) {
                execute("UPDATE committees SET status = 'finished' WHERE committee_id = ?", [$id]);
                committee_event($id, null, 'Everyone has had their turn. The committee is finished.');
            }
        });
    }
    catch (PDOException $error) {
        if (($error->errorInfo[0] ?? '') === '23505') {
            throw new ApiError(409, "{$receiver['display_name']} has already had their turn.");
        }
        throw $error;
    }
    no_content();
}
