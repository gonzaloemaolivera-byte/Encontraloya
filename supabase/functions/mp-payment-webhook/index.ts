import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-signature, x-request-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};
const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing " + name);
  return value;
};
const reply = (status: number, message: string) =>
  new Response(message, { status, headers: cors });
const fromB64Url = (value: string) => {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(
    atob(normalized + "=".repeat((4 - normalized.length % 4) % 4)),
    (char) => char.charCodeAt(0),
  );
};
const toB64Url = (bytes: Uint8Array) => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};
async function decrypt(value: string) {
  const [ivPart, cipherPart] = value.split(".");
  if (!ivPart || !cipherPart) throw new Error("Token cifrado inválido");
  const raw = fromB64Url(env("MP_TOKEN_ENCRYPTION_KEY"));
  if (raw.length !== 32) throw new Error("Clave de cifrado inválida");
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromB64Url(ivPart) },
    key,
    fromB64Url(cipherPart),
  );
  return new TextDecoder().decode(plain);
}
async function encrypt(value: string) {
  const raw = fromB64Url(env("MP_TOKEN_ENCRYPTION_KEY"));
  if (raw.length !== 32) throw new Error("Clave de cifrado inválida");
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(value),
  );
  return toB64Url(iv) + "." + toB64Url(new Uint8Array(cipher));
}
async function sellerToken(admin: any, row: any): Promise<string> {
  const access = await decrypt(row.access_token_enc);
  const expires = new Date(row.expires_at).getTime();
  if (Number.isFinite(expires) && expires > Date.now() + 30 * 24 * 60 * 60 * 1000) {
    return access;
  }
  const form = new URLSearchParams({
    client_id: env("MP_CLIENT_ID"),
    client_secret: env("MP_CLIENT_SECRET"),
    grant_type: "refresh_token",
    refresh_token: await decrypt(row.refresh_token_enc),
  });
  const response = await fetch("https://api.mercadopago.com/oauth/token", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.access_token || !data.refresh_token) {
    throw new Error("No se pudo renovar la autorización de Mercado Pago");
  }
  const expiresAt = new Date(Date.now() + Number(data.expires_in || 15552000) * 1000).toISOString();
  const { error } = await admin.from("mercado_pago_tokens_privado").update({
    access_token_enc: await encrypt(String(data.access_token)),
    refresh_token_enc: await encrypt(String(data.refresh_token)),
    expires_at: expiresAt,
    public_key: data.public_key || row.public_key,
    live_mode: Boolean(data.live_mode),
    scope: data.scope || row.scope,
    actualizado_at: new Date().toISOString(),
  }).eq("comercio_id", row.comercio_id);
  if (error) throw error;
  return String(data.access_token);
}
async function validSignature(req: Request, dataId: string): Promise<boolean> {
  const signature = req.headers.get("x-signature") || "";
  const requestId = req.headers.get("x-request-id") || "";
  const fields = Object.fromEntries(signature.split(",").map((part) => {
    const index = part.indexOf("=");
    return index < 0 ? ["", ""] : [part.slice(0, index).trim(), part.slice(index + 1).trim()];
  }));
  if (!fields.ts || !fields.v1 || !requestId || !dataId) return false;
  const manifest = `id:${dataId};request-id:${requestId};ts:${fields.ts};`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env("MP_WEBHOOK_SECRET")),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifest)));
  const expected = Array.from(digest).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  if (expected.length !== fields.v1.length) return false;
  let diff = 0;
  for (let index = 0; index < expected.length; index++) {
    diff |= expected.charCodeAt(index) ^ fields.v1.charCodeAt(index);
  }
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, "Method not allowed");
  try {
    const url = new URL(req.url);
    const body = await req.json().catch(() => ({}));
    const dataId = url.searchParams.get("data.id") || String(body?.data?.id || "");
    const topic = url.searchParams.get("type") || String(body?.type || "");
    if (topic !== "order") return reply(200, "ok");
    if (!await validSignature(req, dataId)) return reply(401, "Invalid signature");

    const sellerId = String(body?.user_id || "");
    if (!sellerId || !dataId) return reply(400, "Missing order or seller");
    const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: connection, error: connectionError } = await admin.from("conexiones_mercado_pago")
      .select("comercio_id,estado,usuario_mercado_pago_id")
      .eq("usuario_mercado_pago_id", sellerId).eq("estado", "conectado").maybeSingle();
    if (connectionError || !connection) return reply(404, "Unknown seller");
    const { data: tokenRow, error: tokenError } = await admin.from("mercado_pago_tokens_privado")
      .select("*").eq("comercio_id", connection.comercio_id).maybeSingle();
    if (tokenError || !tokenRow) return reply(404, "Missing seller token");

    const token = await sellerToken(admin, tokenRow);
    const response = await fetch("https://api.mercadopago.com/v1/orders/" + encodeURIComponent(dataId), {
      headers: { Authorization: "Bearer " + token, Accept: "application/json" },
    });
    const mpOrder = await response.json().catch(() => ({}));
    if (!response.ok) return reply(502, "Order lookup failed");

    const orderId = String(mpOrder.external_reference || "");
    if (!/^[0-9a-f-]{36}$/i.test(orderId)) return reply(400, "Invalid external reference");
    if (String(mpOrder.id) !== dataId) return reply(400, "Order ID mismatch");
    if (mpOrder.user_id && String(mpOrder.user_id) !== sellerId) return reply(400, "Seller mismatch");
    const currency = String(mpOrder.currency_id || mpOrder.currency || "ARS");
    if (currency !== "ARS") return reply(400, "Currency mismatch");
    const liveMode = Boolean(mpOrder.live_mode ?? body.live_mode);
    if (liveMode !== Boolean(tokenRow.live_mode)) return reply(400, "Environment mismatch");

    const { data: internalOrder, error: internalOrderError } = await admin.from("pedidos")
      .select("id,comercio_id,total,estado").eq("id", orderId).maybeSingle();
    if (internalOrderError || !internalOrder || internalOrder.comercio_id !== connection.comercio_id) {
      return reply(404, "Internal order mismatch");
    }
    if (Math.abs(Number(mpOrder.total_amount) - Number(internalOrder.total)) > 0.01) {
      return reply(400, "Total mismatch");
    }

    const status = String(mpOrder.status || "");
    const totalPaid = Number(mpOrder.total_paid_amount || 0);
    let paymentState = "pendiente";
    if (status === "processed") {
      if (!Number.isFinite(totalPaid) || Math.abs(totalPaid - Number(internalOrder.total)) > 0.01) {
        return reply(400, "Paid amount mismatch");
      }
      paymentState = "aprobado";
    } else if (status === "cancelled" || status === "canceled") {
      paymentState = "cancelado";
    } else if (status === "failed") {
      paymentState = "rechazado";
    } else if (status === "refunded") {
      paymentState = "reembolsado";
    }

    const payments = Array.isArray(mpOrder.transactions?.payments) ? mpOrder.transactions.payments : [];
    const paymentIds = payments.map((payment: any) => String(payment.id || "")).filter(Boolean);
    const amount = status === "processed" ? totalPaid : Number(internalOrder.total);
    const { data: commission, error: commissionError } = await admin.from("comisiones")
      .select("importe_comision").eq("pedido_id", orderId).maybeSingle();
    if (commissionError) throw commissionError;

    const { error: saveError } = await admin.from("pagos").upsert({
      pedido_id: orderId,
      medio_pago: "mercado_pago",
      proveedor: "mercado_pago",
      estado: paymentState,
      importe: amount,
      moneda: "ARS",
      referencia_externa: dataId,
      idempotencia: "mp-order-" + orderId,
      fecha_confirmacion: status === "processed"
        ? (mpOrder.last_updated_date || mpOrder.created_date || new Date().toISOString())
        : null,
      datos_operativos: {
        order_id: dataId,
        order_status: status,
        status_detail: mpOrder.status_detail || null,
        payment_ids: paymentIds,
        live_mode: liveMode,
        updated_at: new Date().toISOString(),
      },
      actualizado_at: new Date().toISOString(),
    }, { onConflict: "idempotencia" });
    if (saveError) throw saveError;

    if (status === "processed") {
      const { error: orderUpdateError } = await admin.from("pedidos").update({
        estado: "confirmado",
        actualizado_at: new Date().toISOString(),
      }).eq("id", orderId).eq("estado", "pendiente");
      if (orderUpdateError) throw orderUpdateError;
      if (commission) {
        const { error: commissionUpdateError } = await admin.from("comisiones").update({
          estado: "cobrada",
          importe_cobrado: Number(commission.importe_comision),
          actualizado_at: new Date().toISOString(),
        }).eq("pedido_id", orderId);
        if (commissionUpdateError) throw commissionUpdateError;
      }
    } else if (status === "refunded") {
      const { error: orderUpdateError } = await admin.from("pedidos").update({
        estado: "reembolsado",
        actualizado_at: new Date().toISOString(),
      }).eq("id", orderId);
      if (orderUpdateError) throw orderUpdateError;
      const { error: commissionUpdateError } = await admin.from("comisiones").update({
        estado: "revertida",
        importe_cobrado: 0,
        actualizado_at: new Date().toISOString(),
      }).eq("pedido_id", orderId);
      if (commissionUpdateError) throw commissionUpdateError;
    } else if (paymentState === "cancelado" || paymentState === "rechazado") {
      await admin.from("pedidos").update({
        estado: "cancelado",
        actualizado_at: new Date().toISOString(),
      }).eq("id", orderId).eq("estado", "pendiente");
    }
    return reply(200, "ok");
  } catch (error) {
    console.error("mp-payment-webhook", error);
    return reply(500, "Webhook processing failed");
  }
});
