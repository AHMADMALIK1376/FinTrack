<?php
/** Activity: the logged-in user's audit log as plain sentences (DB-09). Only their own data (SEC-01). */
declare(strict_types=1);

/** "Rs 8,000" or "Rs 8,500.5" */
function rupees(mixed $value): string
{
    $number = (float) $value;
    $text = number_format($number, 2, '.', ',');
    return 'Rs ' . rtrim(rtrim($text, '0'), '.');
}

function quoted(?string $text): string
{
    return ($text === null || $text === '') ? '' : "\"$text\"";
}

/** Field names shown to people, per table; fields not listed are not mentioned. */
const FIELD_NAMES = [
    'transactions' => ['amount' => 'amount', 'txn_date' => 'date', 'description' => 'description', 'account_id' => 'account', 'category_id' => 'category'],
    'accounts' => ['account_name' => 'name', 'account_type' => 'type'],
    'budgets' => ['limit_amount' => 'limit', 'month' => 'month'],
];

/** One changed value in plain words. */
function show_value(string $field, mixed $value, array $names): string
{
    if ($value === null || $value === '') {
        return 'nothing';
    }
    return match (true) {
        in_array($field, ['amount', 'limit_amount'], true) => rupees($value),
        $field === 'account_id' => $names['accounts'][$value] ?? 'another account',
        $field === 'category_id' => $names['categories'][$value] ?? 'another category',
        $field === 'month' => substr((string) $value, 0, 7),
        default => quoted((string) $value),
    };
}

/**
 * Turns one audit_log row into a sentence, e.g. 'Added "Groceries": −Rs 8,000 from Cash'.
 * @param array $entry audit_log row with old_data / new_data already decoded
 * @param array $names id → name lookups for the user's accounts and categories
 */
function describe_change(array $entry, array $names): string
{
    $old = $entry['old_data'];
    $new = $entry['new_data'];
    $row = $new ?? $old;
    $changes = [];
    if ($entry['action'] === 'UPDATE') {
        foreach (FIELD_NAMES[$entry['table_name']] ?? [] as $field => $label) {
            if (json_encode($old[$field] ?? null) !== json_encode($new[$field] ?? null)) {
                $changes[] = "$label " . show_value($field, $old[$field] ?? null, $names) . ' → ' . show_value($field, $new[$field] ?? null, $names);
            }
        }
    }
    $list = implode(', ', $changes);

    if ($entry['table_name'] === 'transactions') {
        $type = $names['types'][$row['category_id']] ?? null;
        $what = quoted($row['description'] ?? null) ?: ($type ? "an $type" : 'a transaction');
        $account = $names['accounts'][$row['account_id']] ?? 'a deleted account';
        $movement = match ($type) {
            'income' => '+' . rupees($row['amount']) . " to $account",
            'expense' => '−' . rupees($row['amount']) . " from $account",
            default => rupees($row['amount']) . " in $account",
        };
        return match ($entry['action']) {
            'INSERT' => "Added $what: $movement",
            'DELETE' => "Deleted $what ($movement)",
            default => "Changed $what: $list",
        };
    }
    if ($entry['table_name'] === 'accounts') {
        return match ($entry['action']) {
            'INSERT' => 'Added the account ' . quoted($row['account_name']),
            'DELETE' => 'Deleted the account ' . quoted($row['account_name']),
            default => 'Changed the account ' . quoted($old['account_name']) . ": $list",
        };
    }
    $category = $names['categories'][$row['category_id']] ?? 'a category';
    return match ($entry['action']) {
        'INSERT' => 'Set a ' . rupees($row['limit_amount']) . " budget for $category",
        'DELETE' => "Removed the $category budget",
        default => "Changed the $category budget: $list",
    };
}

/** GET /api/activity?limit=20  -> newest first */
function activity_list(array $user): void
{
    $limit = max(1, min(100, (int) (query_param('limit') ?? 20)));
    $uid = $user['id'];
    $log = query(
        'SELECT audit_id, table_name, record_id, action, old_data, new_data,
                to_char(changed_at AT TIME ZONE \'UTC\', \'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"\') AS changed_at,
                changed_by_user_id = ? AS by_me, changed_by_user_id IS NULL AS by_database
         FROM audit_log WHERE owner_user_id = ?
         ORDER BY changed_at DESC, audit_id DESC LIMIT ?', [$uid, $uid, $limit]);
    $names = ['accounts' => [], 'categories' => [], 'types' => []];
    foreach (query('SELECT account_id, account_name FROM accounts WHERE user_id = ?', [$uid]) as $a) {
        $names['accounts'][$a['account_id']] = $a['account_name'];
    }
    foreach (query('SELECT category_id, name, type FROM categories WHERE user_id = ?', [$uid]) as $c) {
        $names['categories'][$c['category_id']] = $c['name'];
        $names['types'][$c['category_id']] = $c['type'];
    }
    $out = [];
    foreach ($log as $entry) {
        $entry['old_data'] = $entry['old_data'] === null ? null : json_decode($entry['old_data'], true);
        $entry['new_data'] = $entry['new_data'] === null ? null : json_decode($entry['new_data'], true);
        $out[] = [
            'audit_id' => $entry['audit_id'],
            'table_name' => $entry['table_name'],
            'record_id' => $entry['record_id'],
            'action' => $entry['action'],
            'changed_at' => $entry['changed_at'],
            'who' => $entry['by_me'] ? 'you' : ($entry['by_database'] ? 'database' : 'someone else'),
            'summary' => describe_change($entry, $names),
        ];
    }
    json_response($out);
}
