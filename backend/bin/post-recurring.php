<?php
/**
 * Daily job: posts every user's due recurring transactions (TXN-07) and rebuilds the
 * FinTrack-wide report averages (DB-12, materialized view report_monthly_averages).
 *   php bin/post-recurring.php
 * Windows: schedule it once with Task Scheduler (see README, "Recurring transactions").
 * Log-ins also post the user's own due rules, so this is only needed when nobody logs in for a while.
 */
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}
require_once __DIR__ . '/../src/env.php';
require_once __DIR__ . '/../src/db.php';

if ($problem = database_settings_problem()) {
    fwrite(STDERR, $problem . PHP_EOL);
    exit(1);
}
try {
    $posted = (int) query_one('SELECT post_due_recurring() AS posted')['posted'];
    echo date('Y-m-d H:i') . " FinTrack: posted $posted recurring transaction" . ($posted === 1 ? '' : 's') . PHP_EOL;
    $refreshed = query_one('SELECT refresh_reports() AS at')['at'];
    echo date('Y-m-d H:i') . " FinTrack: report averages rebuilt at $refreshed" . PHP_EOL;
}
catch (Throwable $error) {
    fwrite(STDERR, 'FinTrack: could not post recurring transactions: ' . $error->getMessage() . PHP_EOL);
    exit(1);
}
