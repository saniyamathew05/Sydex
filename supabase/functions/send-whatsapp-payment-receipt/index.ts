import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const jsonResponse = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return jsonResponse({ error: "Supabase function configuration is missing." }, 500);
    }

    const authorization = req.headers.get("Authorization");
    if (!authorization) return jsonResponse({ error: "Sign in before sending a receipt." }, 401);

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return jsonResponse({ error: "Your session has expired. Sign in again." }, 401);

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .maybeSingle();
    if (profileError) throw profileError;
    if (!profile || !["owner", "salesman"].includes(profile.role)) {
      return jsonResponse({ error: "You are not allowed to send payment receipts." }, 403);
    }

    const body = await req.json();
    const customerId = typeof body.customerId === "string" ? body.customerId.trim() : "";
    const paymentId = typeof body.paymentId === "string" ? body.paymentId.trim() : "";
    const imageBase64 = typeof body.receiptImageBase64 === "string"
      ? body.receiptImageBase64
      : "";
    if (!customerId || !paymentId || body.customerConsented !== true) {
      return jsonResponse({ error: "Customer consent and payment details are required." }, 400);
    }
    if (imageBase64.length === 0 || imageBase64.length > 7_000_000) {
      return jsonResponse({ error: "The receipt image is empty or too large." }, 400);
    }

    const { data: payment, error: paymentError } = await admin
      .from("payments")
      .select("id, customer_id, user_id, amount_received, remaining_balance")
      .eq("id", paymentId)
      .eq("customer_id", customerId)
      .maybeSingle();
    if (paymentError) throw paymentError;
    if (!payment) return jsonResponse({ error: "Saved payment not found." }, 404);
    if (profile.role !== "owner" && payment.user_id !== user.id) {
      return jsonResponse({ error: "You can only send a receipt for a payment you recorded." }, 403);
    }

    const { data: customer, error: customerError } = await admin
      .from("customers")
      .select("business_name, phone")
      .eq("id", customerId)
      .maybeSingle();
    if (customerError) throw customerError;
    if (!customer) return jsonResponse({ error: "Customer not found." }, 404);

    let recipient = String(customer.phone ?? "").replace(/[^0-9]/g, "");
    if (recipient.length === 10) recipient = `91${recipient}`;
    if (recipient.length < 8 || recipient.length > 15) {
      return jsonResponse({ error: "The customer phone number must include a valid country code." }, 400);
    }

    const accessToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN");
    const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
    const templateName = Deno.env.get("WHATSAPP_RECEIPT_TEMPLATE_NAME");
    const templateLanguage = Deno.env.get("WHATSAPP_RECEIPT_TEMPLATE_LANGUAGE") ?? "en";
    const graphVersion = Deno.env.get("WHATSAPP_GRAPH_API_VERSION") ?? "v26.0";
    if (!accessToken || !phoneNumberId || !templateName) {
      return jsonResponse({
        error: "WhatsApp Cloud API is not configured. Add its secrets and an approved image receipt template in Supabase.",
      }, 503);
    }

    const imageBytes = Uint8Array.from(atob(imageBase64), (character) => character.charCodeAt(0));
    const pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (imageBytes.length < 8 || pngSignature.some((byte, index) => imageBytes[index] !== byte)) {
      return jsonResponse({ error: "The receipt must be a PNG image." }, 400);
    }
    if (imageBytes.length > 5_000_000) {
      return jsonResponse({ error: "The receipt image must be smaller than 5 MB." }, 413);
    }

    const baseUrl = `https://graph.facebook.com/${graphVersion}/${phoneNumberId}`;
    const upload = new FormData();
    upload.append("messaging_product", "whatsapp");
    upload.append("file", new Blob([imageBytes], { type: "image/png" }), "payment-receipt.png");
    const uploadResponse = await fetch(`${baseUrl}/media`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}` },
      body: upload,
    });
    const uploaded = await uploadResponse.json();
    if (!uploadResponse.ok || typeof uploaded.id !== "string") {
      console.error("WhatsApp receipt image upload failed:", uploaded.error?.code ?? uploadResponse.status);
      return jsonResponse({ error: "WhatsApp could not upload the receipt image. Check the Cloud API configuration." }, 502);
    }

    const customerName = String(customer.business_name ?? "Customer").slice(0, 120);
    const received = Number(payment.amount_received ?? 0).toFixed(2);
    const balance = Number(payment.remaining_balance ?? 0).toFixed(2);
    const sendResponse = await fetch(`${baseUrl}/messages`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: recipient,
        type: "template",
        template: {
          name: templateName,
          language: { code: templateLanguage },
          components: [
            { type: "header", parameters: [{ type: "image", image: { id: uploaded.id } }] },
            {
              type: "body",
              parameters: [
                { type: "text", text: customerName },
                { type: "text", text: received },
                { type: "text", text: balance },
              ],
            },
          ],
        },
      }),
    });
    const sent = await sendResponse.json();
    if (!sendResponse.ok) {
      console.error("WhatsApp receipt send failed:", sent.error?.code ?? sendResponse.status);
      return jsonResponse({ error: "WhatsApp could not send the receipt. Check the approved template and phone number." }, 502);
    }
    return jsonResponse({ sent: true, messageId: sent.messages?.[0]?.id ?? null });
  } catch (error) {
    console.error("Payment receipt request failed:", error);
    return jsonResponse({ error: "Could not send the WhatsApp receipt." }, 500);
  }
});
