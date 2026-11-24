// Encontralo Ya — mp-oauth-start
// Inicia el flujo OAuth de Mercado Pago para un comercio del titular:
// valida la sesión y la propiedad del comercio, guarda un estado aleatorio
// de un solo uso (solo su hash SHA-256) y devuelve la URL de autorización.
//
// GET con sesión válida devuelve un diagnóstico de configuración que solo
// informa booleanos: nunca expone valores de secretos.
//
// Requiere en Supabase:
//   - Tablas public.mercado_pago_oauth_states_privado y public.comercios.
//   - Secretos de función: MP_CLIENT_ID y MP_REDIRECT_URI (la Redirect URI
//     debe coincidir EXACTAMENTE con la registrada en Mercado Pago
//     Developers; se recortan comillas invertidas y espacios accidentales).
//   - Variables automáticas del runtime: SUPABASE_URL,
//     SUPABASE_SERVICE_ROLE_KEY y SUPABASE_ANON_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: cors });

const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing " + name);
  return value;
};

// Recorta comillas invertidas, comillas y espacios que queden pegados al
// valor al cargar el secreto: un acento grave final en la Redirect URI hace
// que Mercado Pago redirija a una ruta inexistente (404) y que el
// intercambio del código rechace la coincidencia exacta.
const cleanUrl = (value: string) =>
  value
    .trim()
    .replace(/^[`'"\s]+/, "")
    .replace(/[`'"\s]+$/, "");

const hasInvalidEdges = (value: string) => cleanUrl(value) !== value;

const fromB64url = (s: string) => {
  const v = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(v + "=".repeat((4 - (v.length % 4)) % 4)), (c) => c.charCodeAt(0));
};

const b64url = (bytes: Uint8Array) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

const sha256 = async (s: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST" && req.method !== "GET")
    return reply(405, { ok: false, mensaje: "Método no permitido" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return reply(401, { ok: false, mensaje: "Iniciá sesión en el panel del comercio." });
    const url = env("SUPABASE_URL"), anon = env("SUPABASE_ANON_KEY");
    const authClient = createClient(url, anon, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await authClient.auth.getUser(jwt);
    if (userError || !userData.user)
      return reply(401, { ok: false, mensaje: "La sesión venció. Volvé a iniciar sesión." });

    // Diagnóstico de configuración: solo booleanos, sin valores de secretos.
    if (req.method === "GET") {
      const diagnostico: Record<string, boolean> = {};
      const secretValue = (name: string): string | null => {
        const value = Deno.env.get(name);
        return value === null || value === undefined ? null : value;
      };
      const clientId = secretValue("MP_CLIENT_ID");
      diagnostico["client_id_configurada"] = clientId !== null;
      if (clientId !== null) {
        diagnostico["client_id_numerico_valido"] = /^\d{6,25}$/.test(cleanUrl(clientId));
        diagnostico["client_id_con_caracteres_invalidos"] = hasInvalidEdges(clientId);
      }
      const clientSecret = secretValue("MP_CLIENT_SECRET");
      diagnostico["client_secret_configurada"] = clientSecret !== null;
      if (clientSecret !== null) {
        diagnostico["client_secret_con_caracteres_invalidos"] = hasInvalidEdges(clientSecret);
      }
      const redirectUri = secretValue("MP_REDIRECT_URI");
      diagnostico["redirect_uri_configurada"] =
        redirectUri !== null && cleanUrl(redirectUri).length > 0;
      if (redirectUri !== null) {
        diagnostico["redirect_uri_con_caracteres_invalidos"] = hasInvalidEdges(redirectUri);
        diagnostico["redirect_uri_apunta_al_callback"] =
          /^https:\/\/[a-z0-9]+\.supabase\.co\/functions\/v1\/mp-oauth-callback$/i.test(cleanUrl(redirectUri));
      }
      const siteUrl = secretValue("SITE_URL");
      diagnostico["site_url_configurada"] =
        siteUrl !== null && cleanUrl(siteUrl).length > 0;
      if (siteUrl !== null) {
        diagnostico["site_url_con_caracteres_invalidos"] = hasInvalidEdges(siteUrl);
      }
      let tokenKeyValida = false;
      try {
        const keyBytes = fromB64url(cleanUrl(Deno.env.get("MP_TOKEN_ENCRYPTION_KEY") ?? ""));
        tokenKeyValida = keyBytes.length === 32;
      } catch {
        tokenKeyValida = false;
      }
      diagnostico["clave_cifrado_tokens_valida"] = tokenKeyValida;
      return reply(200, { ok: true, diagnostico });
    }

    const body = await req.json().catch(() => ({}));
    const comercioId = String(body.comercio_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(comercioId))
      return reply(400, { ok: false, mensaje: "Comercio inválido." });

    const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: shop, error: shopError } = await admin
      .from("comercios")
      .select("id,propietario_id")
      .eq("id", comercioId)
      .maybeSingle();
    if (shopError || !shop || shop.propietario_id !== userData.user.id)
      return reply(403, { ok: false, mensaje: "No tenés permiso para vincular este comercio." });

    const state = b64url(crypto.getRandomValues(new Uint8Array(32)));
    const { error: stateError } = await admin
      .from("mercado_pago_oauth_states_privado")
      .insert({
        state_hash: await sha256(state),
        comercio_id: comercioId,
        propietario_id: userData.user.id,
        expira_at: new Date(Date.now() + 600000).toISOString(),
      });
    if (stateError) throw stateError;

    const clientId = cleanUrl(env("MP_CLIENT_ID"));
    const redirectUri = cleanUrl(env("MP_REDIRECT_URI"));
    const authUrl = new URL("https://auth.mercadopago.com.ar/authorization");
    authUrl.searchParams.set("client_id", clientId);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("platform_id", "mp");
    authUrl.searchParams.set("state", state);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    return reply(200, { ok: true, authorization_url: authUrl.toString() });
  } catch (error) {
    console.error("mp-oauth-start", error);
    return reply(500, { ok: false, mensaje: "No pudimos iniciar la vinculación con Mercado Pago." });
  }
});
