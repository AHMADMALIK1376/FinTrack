package pk.fintrack.app;

import java.util.regex.Pattern;

/**
 * Decides on the phone which SMS may leave it at all (privacy first):
 *  - only from banks and wallets: names like "HBL" or "JazzCash", or short codes like 8558;
 *    never from a person's phone number (+92..., 03...)
 *  - only messages with an amount (Rs / PKR)
 *  - never codes: anything mentioning an OTP, PIN or verification code stays on the phone
 * The server checks again, but these never even get sent.
 */
final class SmsFilter {
    private static final Pattern PERSONAL_NUMBER = Pattern.compile("^\\+?\\d{10,}$");
    private static final Pattern AMOUNT = Pattern.compile("(?i)\\b(rs\\.?|pkr|rupees)\\s*:?\\s*[\\d,]+");
    private static final Pattern CODE = Pattern.compile("(?i)\\b(otp|one[- ]time|verification code|pass ?code|m?pin)\\b");

    private SmsFilter() {}

    static boolean shouldForward(String sender, String body) {
        if (sender == null || body == null || body.trim().isEmpty()) {
            return false;
        }
        String compact = sender.replaceAll("[\\s()-]", "");
        if (PERSONAL_NUMBER.matcher(compact).matches()) {
            return false;
        }
        return AMOUNT.matcher(body).find() && !CODE.matcher(body).find();
    }
}
