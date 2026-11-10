import { adminClient, authenticatedUser, corsHeaders, json, randomState, requiredEnv, sha256Hex } from "../_shared/mp.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { ok: false, mensaje: "Método no permitido" });
  try {
    const user = await authenticatedUser(req);
    if (!user) return json(401, { ok: false, mensaje: "Iniciá sesión en el panel del comercio." });

    const body = await req.json().catch(() => ({}));
    const comercioId = String(body.comercio_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(comercioId)) return json(400, { ok: false, mensaje: "Comercio inválido." });

    const admin = adminClient();
    const { data: shop, error: shopError } = await admin
      .from("comercios").select("id, propietario_id").eq("id", comercioId).maybeSingle();
    if (shopError || !shop || shop.propietario_id !== user.id) {
      return json(403, { ok: false, mensaje: "No tenés permiso para vincular este comercio." });
    }

    const state = randomState();
    const { error: stateError } = await admin.from("mercado_pago_oauth_states").insert({
      state_hash: await sha256Hex(state),
      comercio_id: comercioId,
      propietario_id: user.id,
      expira_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    });
    if (stateError) throw stateError;

    const clientId = requiredEnv("MP_CLIENT_ID");
    const redirectUri = requiredEnv("MP_REDIRECT_URI");
    const url = new URL("https://auth.mercadopago.com.ar/authorization");
    url.searchParams.set("client_id", clientId);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("platform_id", "mp");
    url.searchParams.set("state", state);
    url.searchParams.set("redirect_uri", redirectUri);
    return json(200, { ok: true, authorization_url: url.toString() });
  } catch (error) {
    console.error("mp-oauth-start:", error);
    return json(500, { ok: false, mensaje: "No pudimos iniciar la vinculación con Mercado Pago." });
  }
});
