<?php
/**
 * Reads a bank, JazzCash or Easypaisa SMS (IM-01).
 *
 * sms_parse() returns what the message says (provider, money in or out, amount, who,
 * transaction ID, date, balance, a category hint), or a short reason it was skipped.
 * Skipped messages are never stored: OTPs and codes, and anything that isn't a payment.
 *
 * Formats differ between banks and change over time, so this looks for the pieces
 * (amount, keywords, "from"/"to"/"at", IDs, dates) rather than matching whole templates.
 * Whatever it reads, the user checks it in the review inbox before anything is added.
 */
declare(strict_types=1);

const SMS_PROVIDERS = [
    // name => pattern on the sender ID and the text (checked in this order)
    'JazzCash' => '/jazz\s*cash|^8558$/i',
    'Easypaisa' => '/easy\s*paisa|^3737$/i',
    'SadaPay' => '/sada\s*pay/i',
    'NayaPay' => '/naya\s*pay/i',
    'Upaisa' => '/upaisa/i',
    'Bank AL Habib' => '/al[\s-]*habib/i',
    'HBL' => '/\bHBL\b|habib bank limited/i',
    'Meezan Bank' => '/meezan/i',
    'UBL' => '/\bUBL\b|united bank/i',
    'MCB' => '/\bMCB\b/i',
    'Allied Bank' => '/\bABL\b|allied bank/i',
    'Bank Alfalah' => '/alfalah/i',
    'Standard Chartered' => '/standard chartered|\bSCB\b/i',
    'Faysal Bank' => '/faysal/i',
    'Askari Bank' => '/askari/i',
    'JS Bank' => '/\bJS\s*Bank\b/i',
    'BankIslami' => '/bank\s*islami/i',
    'National Bank' => '/\bNBP\b|national bank/i',
];

const SMS_CATEGORY_HINTS = [
    'out' => [
        'Food' => '/food\s*panda|\bkfc\b|mcdonald|pizza|restaurant|\bcafe\b|bakery|biryani|cheezious|savour|hardee|burger|dhaba|grocer/i',
        'Transport' => '/careem|\buber\b|in\s*drive|bykea|yango|petrol|fuel|\bpso\b|shell|total parco|attock|m-?tag|motorway/i',
        'Bills' => '/k-?electric|\b(lesco|iesco|mepco|fesco|gepco|pesco|hesco)\b|\bssgc\b|sngpl|ptcl|\bbill\b|electricity|internet|storm\s*fiber|nayatel|top\s*-?up|mobile load|recharge|\b(zong|telenor|ufone)\b/i',
        'Shopping' => '/daraz|amazon|aliexpress|khaadi|gul ahmed|sapphire|outfitters|\bmall\b|imtiaz|carrefour|chase up|metro cash|naheed|\bmart\b/i',
        'Rent' => '/\brent\b/i',
    ],
    'in' => [
        'Salary' => '/salary|payroll/i',
        'Freelance' => '/payoneer|upwork|fiverr|\bwise\b|freelanc/i',
    ],
];

const SMS_MONTHS = ['jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
                    'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12];

/**
 * @param string $receivedOn the day the phone received it (Y-m-d), used when the SMS has no date
 * @return array{provider:string,direction:string,amount:float,counterparty:?string,reference:?string,
 *               txn_date:string,balance_after:?float,category_hint:?string}|string  a reason when skipped
 */
function sms_parse(string $sender, string $text, string $receivedOn): array|string
{
    $text = trim(preg_replace('/\s+/u', ' ', $text) ?? '');
    if ($text === '') {
        return 'The message is empty.';
    }
    // never keep codes: if a message carries an OTP or PIN, it is dropped whatever else it says
    if (preg_match('/\b(OTP|one[- ]time|verification code|pass ?code|\bPIN\b)/i', $text)) {
        return 'Codes and OTPs are never saved.';
    }

    // amounts: "Rs 1,500.00", "Rs.500", "PKR 2,450", with what comes just before each
    preg_match_all('/(?:\bRs\.?|\bPKR|\bRupees)\s*:?\s*([\d,]+(?:\.\d{1,2})?)/i', $text, $found, PREG_OFFSET_CAPTURE | PREG_SET_ORDER);
    $amount = null;
    $balance = null;
    foreach ($found as $match) {
        $value = (float) str_replace(',', '', $match[1][0]);
        $before = substr($text, max(0, $match[0][1] - 28), min(28, $match[0][1]));
        if (preg_match('/(bal(ance)?|avl|available|remaining|limit)\b[^a-z]{0,6}(is\s*)?$/i', $before)) {
            $balance ??= $value;
        } elseif (preg_match('/(fee|charges?|tax|\bFED)\b[^a-z]{0,6}(of\s*|is\s*)?$/i', $before)) {
            continue;
        } elseif ($amount === null && $value > 0) {
            $amount = $value;
        }
    }
    if ($amount === null) {
        return 'No amount in this message, so it isn\'t a payment.';
    }

    // money in or out: whichever kind of word comes first
    $in = '/you have received|\breceived\b|credited|deposited|\bcredit\b(?!\s*card)|cash\s*back|refund(ed)?|to your (a\/c|account|wallet)/i';
    $out = '/\bsent\b|debited|\bpaid\b|payment|purchase|\bspent\b|\bused\b|transferred|withdrawn|withdrawal|\bbill\b|charged|deducted/i';
    $inAt = preg_match($in, $text, $m1, PREG_OFFSET_CAPTURE) ? $m1[0][1] : PHP_INT_MAX;
    $outAt = preg_match($out, $text, $m2, PREG_OFFSET_CAPTURE) ? $m2[0][1] : PHP_INT_MAX;
    if ($inAt === PHP_INT_MAX && $outAt === PHP_INT_MAX) {
        return 'This doesn\'t look like money coming in or going out.';
    }
    $direction = $inAt <= $outAt || preg_match('/you have received|to your (a\/c|account|wallet)/i', $text) ? 'in' : 'out';

    $provider = 'Other';
    foreach (SMS_PROVIDERS as $name => $pattern) {
        if (preg_match($pattern, $sender) || preg_match($pattern, $text)) {
            $provider = $name;
            break;
        }
    }

    $counterparty = sms_counterparty($text, $direction);
    $reference = preg_match('/\b(?:TID|Trx\.?\s*ID|Txn\.?\s*ID|Trans(?:action)?\.?\s*ID|Ref(?:erence)?\.?\s*(?:No\.?|#|ID)?|RRN)\s*[:#.\-]?\s*([A-Z0-9]{6,30})\b/i', $text, $r)
        ? strtoupper($r[1]) : null;

    $hint = null;
    foreach (SMS_CATEGORY_HINTS[$direction] as $category => $pattern) {
        if (preg_match($pattern, ($counterparty ?? '') . ' ' . $text)) {
            $hint = $category;
            break;
        }
    }

    return [
        'provider' => $provider,
        'direction' => $direction,
        'amount' => $amount,
        'counterparty' => $counterparty,
        'reference' => $reference,
        'txn_date' => sms_date($text, $receivedOn),
        'balance_after' => $balance,
        'category_hint' => $hint,
    ];
}

/** Who the money came from (in) or went to (out): "from Ali Raza", "to Sara Malik", "at FOODPANDA". */
function sms_counterparty(string $text, string $direction): ?string
{
    $stop = '(?=\s*(?:\(|\d|\bon\b|\bat\b|\bvia\b|\bin\b|\bto\b|\bfrom\b|\bthrough\b|\bis\b|\bhas\b|\bwas\b|\bwith\b|\bsuccessful|\bdated\b|[.,;:]|\bTID|\bTrx|\bRef|$))';
    $words = $direction === 'in' ? ['from'] : ['at', 'to', 'for'];
    foreach ($words as $word) {
        if (!preg_match_all('/\b' . $word . '\s*:?\s+([A-Za-z][A-Za-z0-9.&\'\- ]{1,60}?)' . $stop . '/i', $text, $all)) {
            continue;
        }
        foreach ($all[1] as $name) {
            $name = trim(preg_replace('/\s+(bill\s*)?payments?$|\s+bill$/i', '', $name) ?? $name, " .-'");
            if ($name === '' || preg_match('/^(rs|pkr|rupees|your|you|the|a\/?c|account|mobile|number|wallet|card|bank|easypaisa|jazzcash)\b/i', $name)) {
                continue;
            }
            if (strtoupper($name) === $name && (str_contains($name, ' ') || strlen($name) > 5)) {   // keep SSGC, PTCL as they are
                $name = ucwords(strtolower($name));   // AHMED KHAN -> Ahmed Khan
            }
            return substr($name, 0, 100);
        }
    }
    return null;
}

/** The date in the message (21-Nov-26, 21/11/2026, 2026-11-21, 21 November 2026), else the day it arrived. */
function sms_date(string $text, string $receivedOn): string
{
    $candidates = [];
    if (preg_match('/\b(\d{4})-(\d{2})-(\d{2})\b/', $text, $m)) {
        $candidates[] = [(int) $m[1], (int) $m[2], (int) $m[3]];
    }
    if (preg_match('/\b(\d{1,2})[-\/ ]([A-Za-z]{3})[a-z]*[-\/ ,]+(\d{2,4})\b/', $text, $m) && isset(SMS_MONTHS[strtolower($m[2])])) {
        $candidates[] = [(int) $m[3], SMS_MONTHS[strtolower($m[2])], (int) $m[1]];
    }
    if (preg_match('/\b(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})\b/', $text, $m)) {
        $candidates[] = [(int) $m[3], (int) $m[2], (int) $m[1]];   // Pakistan writes the day first
    }
    $latest = date('Y-m-d', strtotime($receivedOn . ' +1 day'));
    foreach ($candidates as [$y, $mo, $d]) {
        $y = $y < 100 ? 2000 + $y : $y;
        if (checkdate($mo, $d, $y)) {
            $date = sprintf('%04d-%02d-%02d', $y, $mo, $d);
            if ($date <= $latest && $date >= date('Y-m-d', strtotime($receivedOn . ' -1 year'))) {
                return $date;
            }
        }
    }
    return $receivedOn;
}
