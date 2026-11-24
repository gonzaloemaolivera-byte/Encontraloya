// Encontralo Ya — mp-oauth-callback
// Función pública a la que Mercado Pago devuelve al navegador después de la
// autorización: valida el estado de un solo uso, verifica que el comercio
// siga perteneciendo al titular que inició la conexión, intercambia el código
// por tokens, los cifra y los guarda vinculados al comercio correcto, y
// redirige al panel del comercio. Los tokens nunca salen de esta función.
//
// Requiere en Supabase:
//   - Tablas public.mercado_pago_oauth_states_privado,
//     public.mercado_pago_tokens_privado y public.conexiones_mercado_pago.
//   - Secretos de función: MP_CLIENT_ID, MP_CLIENT_SECRET, MP_REDIRECT_URI
//     (idéntica a la registrada en Mercado Pago Developers, sin caracteres
//     adicionales), MP_TOKEN_ENCRYPTION_KEY (32 bytes Base64URL) y SITE_URL.
//   - Variables automáticas del runtime: SUPABASE_URL,
//     SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Cache-Control": "no-store",
};

const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing " + name);
  return value;
};

// Recorta comillas invertidas, comillas y espacios pegados al valor cargado:
// en el intercambio del código, la Redirect URI debe coincidir EXACTAMENTE
// con la registrada en Mercado Pago Developers.
const cleanUrl = (value: string) =>
  value
    .trim()
    .replace(/^[`'"\s]+/, "")
    .replace(/[`'"\s]+$/, "");

const b64url = (bytes: Uint8Array) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

const fromB64url = (s: string) => {
  const v = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(v + "=".repeat((4 - (v.length % 4)) % 4)), (c) => c.charCodeAt(0));
};

const sha256 = async (s: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

async function encrypt(value: string) {
  const keyBytes = fromB64url(cleanUrl(env("MP_TOKEN_ENCRYPTION_KEY")));
  if (keyBytes.length !== 32) throw new Error("MP_TOKEN_ENCRYPTION_KEY debe ser 32 bytes Base64URL");
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value));
  return b64url(iv) + "." + b64url(new Uint8Array(data));
}

const redirect = (path: string) =>
  Response.redirect(new URL(path, cleanUrl(env("SITE_URL"))).toString(), 303);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "GET")
    return new Response("Método no permitido", { status: 405, headers: cors });
  try {
    const incoming = new URL(req.url);
    const code = incoming.searchParams.get("code");
    const state = incoming.searchParams.get("state");

    // El titular negó la autorización o Mercado Pago devolvió un error.
    if (incoming.searchParams.get("error") || !code || !state)
      return redirect("/panel-comercio.html?mp=error");

    const admin = createClient(cleanUrl(env("SUPABASE_URL")), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const hash = await sha256(state);
    const { data: pending, error } = await admin
      .from("mercado_pago_oauth_states_privado")
      .select("comercio_id,propietario_id,expira_at,usado_at")
      .eq("state_hash", hash)
      .maybeSingle();
    if (error || !pending || pending.usado_at || new Date(pending.expira_at).getTime() < Date.now())
      return redirect("/panel-comercio.html?mp=state_error");

    // Consume el estado de un solo uso: solo el primer intento lo reclama.
    const { data: claimed, error: claimError } = await admin
      .from("mercado_pago_oauth_states_privado")
      .update({ usado_at: new Date().toISOString() })
      .eq("state_hash", hash)
      .is("usado_at", null)
      .gt("expira_at", new Date().toISOString())
      .select("comercio_id,propietario_id")
      .maybeSingle();
    if (claimError || !claimed) return redirect("/panel-comercio.html?mp=state_error");

    const { data: currentShop, error: ownerCheckError } = await admin
      .from("comercios")
      .select("propietario_id")
      .eq("id", claimed.comercio_id)
      .maybeSingle();
    if (ownerCheckError || !currentShop || currentShop.propietario_id !== claimed.propietario_id)
      return redirect("/panel-comercio.html?mp=owner_changed");

    const form = new URLSearchParams({
      client_id: cleanUrl(env("MP_CLIENT_ID")),
      client_secret: env("MP_CLIENT_SECRET").trim(),
      grant_type: "authorization_code",
      code,
      redirect_uri: cleanUrl(env("MP_REDIRECT_URI")),
      state,
    });

    const response = await fetch("https://api.mercadopago.com/oauth/token", {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
      body: form,
    });
    const credentials = await response.json().catch(() => ({}));
    if (
      !response.ok ||
      !credentials.access_token ||
      !credentials.refresh_token ||
      !credentials.user_id ||
      typeof credentials.live_mode !== "boolean"
    ) {
      // No se simula una conexión exitosa: falla explícita con detalle
      // interno solo en el registro de la función.
      console.error("OAuth token exchange", response.status, credentials.error || credentials.message);
      return redirect("/panel-comercio.html?mp=exchange_error");
    }

    const grantedScopes = String(credentials.scope || "").split(/\s+/).filter(Boolean);
    if (!grantedScopes.includes("offline_access")) {
      console.error("OAuth missing offline_access scope");
      return redirect("/panel-comercio.html?mp=offline_access_missing");
    }

    const expiresAt = new Date(Date.now() + Number(credentials.expires_in || 15552000) * 1000).toISOString();
    const { error: saveError } = await admin.from("mercado_pago_tokens_privado").upsert(
      {
        comercio_id: claimed.comercio_id,
        usuario_mercado_pago_id: String(credentials.user_id),
        access_token_enc: await encrypt(String(credentials.access_token)),
        refresh_token_enc: await encrypt(String(credentials.refresh_token)),
        public_key: credentials.public_key || null,
        live_mode: Boolean(credentials.live_mode),
        scope: credentials.scope || null,
        expires_at: expiresAt,
        actualizado_at: new Date().toISOString(),
      },
      { onConflict: "comercio_id" },
    );
    if (saveError) throw saveError;

    const { error: statusError } = await admin.from("conexiones_mercado_pago").upsert(
      {
        comercio_id: claimed.comercio_id,
        usuario_mercado_pago_id: String(credentials.user_id),
        estado: "conectado",
        alcance_autorizado: String(credentials.scope || "").split(" ").filter(Boolean),
        conectado_at: new Date().toISOString(),
        desconectado_at: null,
      },
      { onConflict: "comercio_id" },
    );
    if (statusError) throw statusError;

    return redirect("/panel-comercio.html?mp=connected");
  } catch (error) {
    console.error("mp-oauth-callback", error);
    return redirect("/panel-comercio.html?mp=error");
  }
});
