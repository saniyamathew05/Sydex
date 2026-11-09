# WhatsApp payment receipt setup

The payment screen can send a PNG receipt through the WhatsApp Cloud API after
the payment is saved. The customer must agree to receive WhatsApp messages.
The app does not send the Meta access token to the device.

## Meta setup

1. In Meta for Developers, create or open a business app and add the WhatsApp
   product. Connect the WhatsApp Business Account and the business phone number.
2. From the WhatsApp API setup page, copy the **Phone number ID**. Create a
   system-user access token with the WhatsApp messaging permission for the
   connected account. Do not put this token in Flutter or Git.
3. In WhatsApp Manager, create and get approval for a **Utility** message
   template with an **Image** header and this body (three placeholders, in
   order):

   `Hello {{1}}, we received ₹{{2}}. Your pending balance is ₹{{3}}. Please see the attached payment receipt.`

   Example template name: `payment_receipt`; language: `en`.
4. In Supabase Dashboard → Edge Functions → Secrets, add:
   - `WHATSAPP_ACCESS_TOKEN`
   - `WHATSAPP_PHONE_NUMBER_ID`
   - `WHATSAPP_RECEIPT_TEMPLATE_NAME`
   - `WHATSAPP_RECEIPT_TEMPLATE_LANGUAGE` (for example `en`)
   - `WHATSAPP_GRAPH_API_VERSION` (defaults to `v26.0`)
5. Deploy `send-whatsapp-payment-receipt` with JWT verification enabled. The
   Supabase service role key remains server-side in the Edge Function runtime.

The function reads the customer number and saved payment details from
Supabase, uploads the receipt image to Meta, and sends it with the approved
image-header template. It requires a valid customer phone number and an
explicit confirmation in the payment screen.
