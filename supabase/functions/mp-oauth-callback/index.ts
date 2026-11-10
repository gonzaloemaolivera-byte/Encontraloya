import { adminClient, corsHeaders, encryptToken, requiredEnv, sha256Hex } from "../_shared/mp.ts";

function redirect(path: string) {
  const base = requiredEnv("SITE_URL");
  const url = new URL(path, base);
  return Response.redirect(url.toString(), 303);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return new Response("Método no permitido", { status: 405, headers: corsHeaders });
  try {
    const incoming = new URL(req.url);
    const code = incoming.searchParams.get("code");
    const state = incoming.searchParams.get("state");
    const mpError = incoming.searchParams.get("error");
    if (mpError || !code || !state) return redirect("/panel-comercio.html?mp=error");

    const admin = adminClient();
    const stateHash = await sha256Hex(state);
    const { data: pending, error: stateError } = await admin
      .from("mercado_pago_oauth_states")
      .select("comercio_id, propietario_id, expira_at, usado_at")
      .eq("state_hash", stateHash).maybeSingle();
    if (stateError || !pending || pending.usado_at || new Date(pending.expira_at).getTime() < Date.now()) {
      return redirect("/panel-comercio.html?mp=state_error");
    }
    const { data: claimed, error: claimError } = await admin
      .from("mercado_pago_oauth_states")
      .update({ usado_at: new Date().toISOString() })
      .eq("state_hash", stateHash).is("usado_at", null).gt("expira_at", new Date().toISOString())
      .select("comercio_id, propietario_id").maybeSingle();
    if (claimError || !claimed) return redirect("/panel-comercio.html?mp=state_error");

    const clientId = requiredEnv("MP_CLIENT_ID");
    const clientSecret = requiredEnv("MP_CLIENT_SECRET");
    const redirectUri = requiredEnv("MP_REDIRECT_URI");
    const form = new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      state,
    });
    const response = await fetch("https://api.mercadopago.com/oauth/token", {
      method: "POST",
      headers: { "Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded" },
      body: form,
    });
    const credentials = await response.json().catch(() => ({}));
    if (!response.ok || !credentials.access_token || !credentials.refresh_token || !credentials.user_id) {
      console.error("Mercado Pago OAuth exchange failed:", response.status, credentials.error || credentials.message || "sin detalle");
      return redirect("/panel-comercio.html?mp=exchange_error");
    }

    const expiresAt = new Date(Date.now() + Number(credentials.expires_in || 15552000) * 1000).toISOString();
    const { error: saveError } = await admin.schema("private").from("mercado_pago_tokens").upsert({
      comercio_id: claimed.comercio_id,
      usuario_mercado_pago_id: String(credentials.user_id),
      access_token_enc: await encryptToken(String(credentials.access_token)),
      refresh_token_enc: await encryptToken(String(credentials.refresh_token)),
      public_key: credentials.public_key || null,
      live_mode: Boolean(credentials.live_mode),
      scope: credentials.scope || null,
      expires_at: expiresAt,
      actualizado_at: new Date().toISOString(),
    }, { onConflict: "comercio_id" });
    if (saveError) throw saveError;

    const { error: statusError } = await admin.from("conexiones_mercado_pago").upsert({
      comercio_id: claimed.comercio_id,
      usuario_mercado_pago_id: String(credentials.user_id),
      estado: "conectado",
      alcance_autorizado: String(credentials.scope || "").split(" ").filter(Boolean),
      conectado_at: new Date().toISOString(),
      desconectado_at: null,
    }, { onConflict: "comercio_id" });
    if (statusError) throw statusError;

    return redirect("/panel-comercio.html?mp=connected");
  } catch (error) {
    console.error("mp-oauth-callback:", error);
    return redirect("/panel-comercio.html?mp=error");
  }
});
