package pk.fintrack.app;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/** What may leave the phone (IM-07): only bank and wallet payments, never personal messages or codes. */
public class SmsFilterTest {
    @Test
    public void bankAndWalletPaymentsAreSent() {
        assertTrue(SmsFilter.shouldForward("JazzCash", "You have received Rs 1,500.00 from ALI RAZA. TID 0123"));
        assertTrue(SmsFilter.shouldForward("8558", "Rs 500.00 sent to Sara Malik. TID 0123456789"));
        assertTrue(SmsFilter.shouldForward("HBL", "Your HBL Debit Card was used for PKR 2,450.00 at FOODPANDA"));
        assertTrue(SmsFilter.shouldForward("Easypaisa", "You have successfully sent Rs.1,000 to Bilal"));
    }

    @Test
    public void messagesFromPeopleStayOnThePhone() {
        assertFalse(SmsFilter.shouldForward("+923001234567", "Bhai Rs 500 bhej do"));
        assertFalse(SmsFilter.shouldForward("0300 1234567", "Rs 2000 de dena kal"));
        assertFalse(SmsFilter.shouldForward("Mom", "Beta khana kha liya?"));
    }

    @Test
    public void codesNeverLeaveThePhone() {
        assertFalse(SmsFilter.shouldForward("HBL", "Your OTP for transaction of Rs 5,000 is 123456"));
        assertFalse(SmsFilter.shouldForward("JazzCash", "Your MPIN for Rs 100 transfer is 4455"));
        assertFalse(SmsFilter.shouldForward("Meezan", "Verification code 778899 for PKR 9,000 payment"));
    }

    @Test
    public void messagesWithoutAnAmountStayOnThePhone() {
        assertFalse(SmsFilter.shouldForward("Zong", "Dear customer your balance is low"));
        assertFalse(SmsFilter.shouldForward("JazzCash", ""));
    }
}
