<?php
/**
 * SMS import (IM-01 - IM-07): the user's phone forwards bank, JazzCash and Easypaisa SMS to
 * POST /api/sms/{key}. FinTrack reads each one (sms_parser.php) and puts it in the review inbox.
 * Nothing is added to the user's accounts until they press Add (add_imported_message() in 13_imports.sql).
 *
 * The key is long and random, so the address works without logging in, which forwarding apps can't do.
 * Only its SHA-256 hash is stored, so a copy of the database doesn't reveal it, and the user can
 * replace it or turn it off at any time.
 */
declare(strict_types=1);

require_once __DIR__ . '/../sms_parser.php';

const SMS_RATE_LIMIT = 100;   // saved messages per user in 10 minutes

/** Saves one message for a user. Returns ['saved' => bool, 'reason' => ?, 'import_id' => ?, 'status' => ?]. */
function import_save_message(int $userId, string $source, string $sender, string $text, string $receivedAt): array
{
    $sender = mb_substr(trim($sender), 0, 40);
    $text = mb_substr(trim($text), 0, 1000);
    $parsed = sms_parse($sender, $text, substr($receivedAt, 0, 10));
    if (is_string($parsed)) {
        return ['saved' => false, 'reason' => $parsed];
    }
    $row = query_one(
        'INSERT INTO imported_messages (user_id, source, sender, body, received_at, provider, direction, amount, counterparty,
                                        reference, txn_date, balance_after, category_hint)
         VALUES (?, ?, ?, ?, CAST(? AS timestamptz), ?, ?, ?, ?, ?, CAST(? AS date), ?, ?)
         ON CONFLICT (user_id, body_hash) DO NOTHING
         RETURNING import_id, status',
        [$userId, $source, $sender, $text, $receivedAt, $parsed['provider'], $parsed['direction'], $parsed['amount'],
         $parsed['counterparty'], $parsed['reference'], $parsed['txn_date'], $parsed['balance_after'], $parsed['category_hint']]);
    if ($row === null) {
        return ['saved' => false, 'reason' => 'This message was already received.'];
    }
    return ['saved' => true, 'import_id' => $row['import_id'], 'status' => $row['status']];
}

/** What a forwarding app sent: JSON, a form, or plain text. Different apps name the fields differently. */
function sms_incoming(): array
{
    $raw = (string) file_get_contents('php://input');
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        $data = $_POST ?: [];
        if (!$data) {
            parse_str($raw, $data);
            if (count($data) === 1 && reset($data) === '') {   // plain text body, not a form
                $data = [];
            }
        }
    }
    $pick = function (array $names) use ($data): string {
        foreach ($names as $name) {
            if (isset($data[$name]) && is_scalar($data[$name]) && trim((string) $data[$name]) !== '') {
                return trim((string) $data[$name]);
            }
        }
        return '';
    };
    $text = $pick(['text', 'message', 'body', 'msg', 'content', 'sms']);
    if ($text === '' && !$data) {
        $text = trim($raw);
    }
    $time = $pick(['receivedStamp', 'received_at', 'timestamp', 'time', 'date', 'sentStamp']);
    $at = null;
    if ($time !== '') {
        $at = ctype_digit($time) ? (int) (strlen($time) > 10 ? intdiv((int) $time, 1000) : $time) : strtotime($time);
    }
    if (!$at || $at > time() + 86400 || $at < time() - 400 * 86400) {
        $at = time();
    }
    return ['sender' => $pick(['from', 'sender', 'phone', 'number', 'address', 'title']), 'text' => $text, 'at' => date('c', $at)];
}

/** POST /api/sms/{key}: called by the forwarding app on the user's phone, without logging in. */
function sms_receive(string $key): void
{
    $owner = query_one('SELECT user_id FROM sms_keys WHERE token_hash = ?', [hash('sha256', $key)]);
    if ($owner === null) {
        throw new ApiError(404, 'Not found.');
    }
    $userId = (int) $owner['user_id'];
    $recent = query_one("SELECT COUNT(*)::INT AS n FROM imported_messages WHERE user_id = ? AND received_at > NOW() - INTERVAL '10 minutes'
                         AND source = 'sms'", [$userId]);
    if ($recent['n'] >= SMS_RATE_LIMIT) {
        throw new ApiError(429, 'Too many messages in a short time. Please try again later.');
    }
    $in = sms_incoming();
    execute('UPDATE sms_keys SET last_used_at = NOW() WHERE user_id = ?', [$userId]);
    // 200 even when skipped, so the phone doesn't keep retrying a message we chose not to keep
    json_response(import_save_message($userId, 'sms', $in['sender'], $in['text'], $in['at']));
}

/** GET /api/sms/key: is forwarding on, and when was it last used. The key itself is never shown again. */
function sms_key_get(array $user): void
{
    $row = query_one('SELECT created_at, last_used_at FROM sms_keys WHERE user_id = ?', [$user['id']]);
    json_response(['active' => $row !== null, 'created_at' => $row['created_at'] ?? null, 'last_used_at' => $row['last_used_at'] ?? null]);
}

/** POST /api/sms/key: make a new private key (the old one stops working). Shown once. */
function sms_key_create(array $user): void
{
    $key = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
    execute('INSERT INTO sms_keys (user_id, token_hash) VALUES (?, ?)
             ON CONFLICT (user_id) DO UPDATE SET token_hash = EXCLUDED.token_hash, created_at = NOW(), last_used_at = NULL',
        [$user['id'], hash('sha256', $key)]);
    json_response(['key' => $key, 'path' => '/api/sms/' . $key], 201);
}

/** DELETE /api/sms/key: turn forwarding off. */
function sms_key_delete(array $user): void
{
    execute('DELETE FROM sms_keys WHERE user_id = ?', [$user['id']]);
    no_content();
}

/**
 * GET /api/imports?status=pending|added|ignored|duplicate|all
 * For waiting messages, also a transaction that may be the same one already typed in by hand (IM-03).
 */
function imports_list(array $user): void
{
    $status = (string) (query_param('status') ?? 'pending');
    if (!in_array($status, ['pending', 'added', 'ignored', 'duplicate', 'all'], true)) {
        throw new ApiError(400, 'A value has the wrong format.');
    }
    $items = query(
        "SELECT m.import_id, m.source, m.sender, m.body, m.received_at, m.provider, m.direction, m.amount, m.counterparty,
                m.reference, m.txn_date, m.balance_after, m.suggested_account_id, m.suggested_category_id, m.status,
                m.duplicate_of, m.transaction_id, m.decided_at, a.account_name, c.name AS category,
                (SELECT json_build_object('transaction_id', t.transaction_id, 'txn_date', t.txn_date, 'description', t.description,
                                          'account_name', ta.account_name)
                 FROM transactions t
                 JOIN accounts ta    ON ta.account_id = t.account_id AND ta.user_id = m.user_id
                 JOIN categories tc  ON tc.category_id = t.category_id
                 WHERE m.status = 'pending' AND t.amount = m.amount
                   AND tc.type = (CASE m.direction WHEN 'in' THEN 'income' ELSE 'expense' END)::category_kind
                   AND t.txn_date BETWEEN m.txn_date - 2 AND m.txn_date + 2
                   AND NOT EXISTS (SELECT 1 FROM imported_messages x WHERE x.transaction_id = t.transaction_id)
                 ORDER BY ABS(t.txn_date - m.txn_date) LIMIT 1) AS maybe_same
         FROM imported_messages m
         LEFT JOIN transactions t ON t.transaction_id = m.transaction_id
         LEFT JOIN accounts a     ON a.account_id = t.account_id
         LEFT JOIN categories c   ON c.category_id = t.category_id
         WHERE m.user_id = ? AND (? = 'all' OR m.status = CAST(? AS import_status))
         ORDER BY m.received_at DESC, m.import_id DESC
         LIMIT 100", [$user['id'], $status, $status === 'all' ? 'pending' : $status]);
    foreach ($items as &$item) {
        $item['maybe_same'] = $item['maybe_same'] === null ? null : json_decode($item['maybe_same'], true);
    }
    unset($item);
    $counts = query_one(
        "SELECT COUNT(*) FILTER (WHERE status = 'pending')::INT AS pending,
                COUNT(*) FILTER (WHERE status = 'added' AND decided_at >= DATE_TRUNC('month', NOW()))::INT AS added_this_month,
                COUNT(*) FILTER (WHERE status = 'duplicate')::INT AS duplicates,
                COUNT(*) FILTER (WHERE status = 'ignored')::INT AS ignored,
                COUNT(*) FILTER (WHERE status = 'added')::INT AS added
         FROM imported_messages WHERE user_id = ?", [$user['id']]);
    json_response(['items' => $items, 'counts' => $counts]);
}

/** POST /api/imports/test  { text, sender? }: try a message without a phone (also used in the demo). */
function imports_test(array $user): void
{
    $body = request_body();
    $text = trim((string) field($body, 'text'));
    if ($text === '') {
        throw new ApiError(400, 'Paste or type a message to try.');
    }
    $result = import_save_message($user['id'], 'test', (string) (field($body, 'sender') ?? ''), $text, date('c'));
    json_response($result, $result['saved'] ? 201 : 200);
}

/** The user's own message, or a 404. */
function import_for(int $userId, int $id): array
{
    $row = query_one('SELECT * FROM imported_messages WHERE import_id = ? AND user_id = ?', [$id, $userId]);
    if ($row === null) {
        throw new ApiError(404, 'Message not found.');
    }
    return $row;
}

/** POST /api/imports/{id}/add  { account_id, category_id, amount?, txn_date?, description? } (IM-04) */
function imports_add(array $user, int $id): void
{
    import_for($user['id'], $id);
    $body = request_body();
    if (field($body, 'account_id') === null || field($body, 'category_id') === null) {
        throw new ApiError(400, 'Choose an account and a category.');
    }
    $txn = in_transaction($user['id'], fn () => query_one(
        'SELECT add_imported_message(?, ?, ?, ?, ?, CAST(? AS date), ?) AS id',
        [$id, $user['id'], field($body, 'account_id'), field($body, 'category_id'), field($body, 'amount'),
         field($body, 'txn_date'), field($body, 'description')])['id']);
    json_response(['transaction_id' => $txn], 201);
}

/** POST /api/imports/{id}/ignore: not a transaction to keep (e.g. between my own accounts). */
function imports_ignore(array $user, int $id): void
{
    $m = import_for($user['id'], $id);
    if ($m['status'] === 'added') {
        throw new ApiError(400, 'This message has already been added. Delete the transaction instead.');
    }
    execute("UPDATE imported_messages SET status = 'ignored', decided_at = NOW() WHERE import_id = ?", [$id]);
    no_content();
}

/** POST /api/imports/{id}/restore: back to the inbox (an ignored message, or a "duplicate" that wasn't one). */
function imports_restore(array $user, int $id): void
{
    $m = import_for($user['id'], $id);
    if (!in_array($m['status'], ['ignored', 'duplicate'], true)) {
        throw new ApiError(400, 'Only ignored messages and duplicates can go back to the inbox.');
    }
    execute("UPDATE imported_messages SET status = 'pending', decided_at = NULL WHERE import_id = ?", [$id]);
    no_content();
}

/** DELETE /api/imports/{id}: forget the message text. A transaction made from it stays. */
function imports_delete(array $user, int $id): void
{
    import_for($user['id'], $id);
    execute('DELETE FROM imported_messages WHERE import_id = ?', [$id]);
    no_content();
}
