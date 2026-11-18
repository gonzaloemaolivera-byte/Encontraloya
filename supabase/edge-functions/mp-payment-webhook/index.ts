import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const headers = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};
const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing " + name);
  return value;
};
const b64 = (s: string) => {
  const v = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(v + "=".repeat((4 - v.length % 4) % 4)), c => c.charCodeAt(0));
};
const toB64 = (bytes: Uint8Array) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers });

async function decrypt(value: string) {
  const [iv, cipher] = value.split(".");
  if (!iv || !cipher) throw new Error("Encrypted token format invalid");
  const raw = b64(env("MP_TOKEN_ENCRYPTION_KEY"));
  if (raw.length !== 32) throw new Error("Encryption key must be 32 bytes");
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64(iv) }, key, b64(cipher));
  return new TextDecoder().decode(plain);
}
async function encrypt(value: string) {
  const raw = b64(env("MP_TOKEN_ENCRYPTION_KEY"));
  if (raw.length !== 32) throw new Error("Encryption key must be 32 bytes");
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value));
  return toB64(iv) + "." + toB64(new Uint8Array(cipher));
}
async function verifySignature(req: Request, dataId: string) {
  const signature = req.headers.get("x-signature") || "";
  const requestId = req.headers.get("x-request-id") || "";
  const fields: Record<string, string> = {};
  for (const part of signature.split(",")) {
    const pos = part.indexOf("=");
    if (pos > 0) fields[part.slice(0, pos).trim()] = part.slice(pos + 1).trim();
  }
  if (!fields.ts || !fields.v1 || !requestId || !dataId) return false;
  const manifest = `id:${dataId};request-id:${requestId};ts:${fields.ts};`;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(env("MP_WEBHOOK_SECRET")),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifest)));
  const expected = Array.from(digest).map(b => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== fields.v1.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ fields.v1.toLowerCase().charCodeAt(i);
  return diff === 0;
}
async function getSellerAccessToken(admin: any, row: any) {
  if (new Date(row.expires_at).getTime() > Date.now() + 10 * 60 * 1000) {
    return await decrypt(row.access_token_enc);
  }
  const refresh = await decrypt(row.refresh_token_enc);
  const form = new URLSearchParams({
    client_id: env("MP_CLIENT_ID"),
    client_secret: env("MP_CLIENT_SECRET"),
    grant_type: "refresh_token",
    refresh_token: refresh,
  });
  const response = await fetch("https://api.mercadopago.com/oauth/token", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });
  const credentials = await response.json().catch(() => ({}));
  if (!response.ok || !credentials.access_token || !credentials.refresh_token) {
    throw new Error("Seller authorization expired; reconnection required");
  }
  const expiresAt = new Date(Date.now() + Number(credentials.expires_in || 15552000) * 1000).toISOString();
  const update: Record<string, unknown> = {
    access_token_enc: await encrypt(String(credentials.access_token)),
    refresh_token_enc: await encrypt(String(credentials.refresh_token)),
    expires_at: expiresAt,
    actualizado_at: new Date().toISOString(),
  };
  if (credentials.public_key) update.public_key = String(credentials.public_key);
  if (typeof credentials.live_mode === "boolean" && credentials.live_mode !== row.live_mode) {
    throw new Error("Mercado Pago token environment changed; seller must reconnect");
  }
  const { error } = await admin.from("mercado_pago_tokens_privado")
    .update(update).eq("comercio_id", row.comercio_id);
  if (error) throw error;
  return String(credentials.access_token);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  try {
    const url = new URL(req.url);
    const body = await req.json().catch(() => ({}));
    const dataId = url.searchParams.get("data.id") || String(body?.data?.id || "");
    const topic = url.searchParams.get("type") || String(body?.type || "");
    if (topic !== "payment") return json(200, { ok: true, ignored: true });
    if (!/^\d+$/.test(dataId) || !await verifySignature(req, dataId)) {
      return json(401, { ok: false, error: "invalid_signature" });
    }

    const sellerId = String(body?.user_id || "");
    if (!sellerId) return json(400, { ok: false, error: "missing_seller" });

    const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: connection, error: connectionError } = await admin
      .from("conexiones_mercado_pago")
      .select("comercio_id,estado,usuario_mercado_pago_id")
      .eq("usuario_mercado_pago_id", sellerId).eq("estado", "conectado").maybeSingle();
    if (connectionError) throw connectionError;
    if (!connection) return json(404, { ok: false, error: "unknown_seller" });

    const { data: tokenRow, error: tokenError } = await admin
      .from("mercado_pago_tokens_privado").select("*")
      .eq("comercio_id", connection.comercio_id).maybeSingle();
    if (tokenError) throw tokenError;
    if (!tokenRow || String(tokenRow.usuario_mercado_pago_id) !== sellerId) {
      return json(409, { ok: false, error: "seller_reauthorization_required" });
    }

    const accessToken = await getSellerAccessToken(admin, tokenRow);
    const paymentResponse = await fetch(
      "https://api.mercadopago.com/v1/payments/" + encodeURIComponent(dataId),
      { headers: { Authorization: "Bearer " + accessToken } },
    );
    const payment = await paymentResponse.json().catch(() => ({}));
    if (!paymentResponse.ok) {
      // 5xx/429 from MP are retryable; invalid payment IDs are rejected.
      return json(paymentResponse.status >= 500 || paymentResponse.status === 429 ? 503 : 404,
        { ok: false, error: "payment_lookup_failed" });
    }

    const orderId = String(payment.external_reference || "");
    if (!/^[0-9a-f-]{36}$/i.test(orderId) ||
        String(payment.collector_id) !== sellerId ||
        payment.currency_id !== "ARS" ||
        typeof payment.live_mode !== "boolean" ||
        payment.live_mode !== Boolean(tokenRow.live_mode)) {
      return json(400, { ok: false, error: "payment_mismatch" });
    }
    const { data: order, error: orderError } = await admin.from("pedidos")
      .select("id,comercio_id,total,moneda").eq("id", orderId).maybeSingle();
    if (orderError) throw orderError;
    if (!order || order.comercio_id !== connection.comercio_id ||
        order.moneda !== "ARS" ||
        Math.abs(Number(payment.transaction_amount) - Number(order.total)) > 0.01) {
      return json(400, { ok: false, error: "order_mismatch" });
    }

    const { data: result, error: processError } = await admin.rpc("procesar_pago_mercado_pago_webhook", {
      p_pedido_id: orderId,
      p_comercio_id: connection.comercio_id,
      p_payment_id: dataId,
      p_payment_status: String(payment.status || ""),
      p_importe: Number(payment.transaction_amount),
      p_moneda: String(payment.currency_id),
      p_live_mode: Boolean(payment.live_mode),
      p_fecha_aprobacion: payment.date_approved || null,
      p_datos_operativos: {
        payment_id: dataId,
        payment_status: String(payment.status || ""),
        status_detail: payment.status_detail || null,
        payment_type_id: payment.payment_type_id || null,
        live_mode: Boolean(payment.live_mode),
        updated_at: new Date().toISOString(),
      },
    });
    if (processError) throw processError;
    return json(200, { ok: true, result });
  } catch (error) {
    // Do not log tokens, full provider payloads, or personal data.
    console.error("mp-payment-webhook", error instanceof Error ? error.message : "unknown_error");
    return json(503, { ok: false, error: "webhook_processing_failed_retryable" });
  }
});
