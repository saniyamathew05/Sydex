import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return json({ error: "Sign in is required." }, 401);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return json({ error: "Function is not configured." }, 500);
  const userClient = createClient(url, anon, { global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data, error } = await userClient.auth.getUser(token);
  if (error || !data.user) return json({ error: "Your session is invalid or expired." }, 401);
  const { error: prepareError } = await userClient.rpc("prepare_my_account_deletion");
  if (prepareError) return json({ error: prepareError.message }, 409);
  const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } });
  const { error: deleteError } = await admin.auth.admin.deleteUser(data.user.id);
  if (deleteError) return json({ error: deleteError.message }, 500);
  return json({ success: true });
});

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}
