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
const reply = (status: number, message: string) => new Response(message, { status, headers: cors });
const fromB64Url = (value: string) => {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(normalized + "=".repeat((4 - normalized.length % 4) % 4)), (char) => char.charCodeAt(0));
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
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64Url(ivPart) }, key, fromB64Url(cipherPart));
  return new TextDecoder().decode(plain);
}
async function encrypt(value: string) {
  const raw = fromB64Url(env("MP_TOKEN_ENCRYPTION_KEY"));
  if (raw.length !== 32) throw new Error("Clave de cifrado inválida");
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value));
  return toB64Url(iv) + "." + toB64Url(new Uint8Array(cipher));
}
async function sellerToken(admin: any, row: any): Promise<string> {
  const access = await decrypt(row.access_token_enc);
  const expires = new Date(row.expires_at).getTime();
  if (Number.isFinite(expires) && expires > Date.now() + 30 * 24 * 60 * 60 * 1000) return access;
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
  if (!response.ok || !data.access_token || !data.refresh_token || typeof data.live_mode !== "boolean" || Boolean(data.live_mode) !== Boolean(row.live_mode)) throw new Error("No se pudo renovar la autorización en el mismo entorno de Mercado Pago");
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
  const manifest = `id:${dataId.toLowerCase()};request-id:${requestId};ts:${fields.ts};`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env("MP_WEBHOOK_SECRET")), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifest)));
  const expected = Array.from(digest).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  if (expected.length !== fields.v1.length) return false;
  let diff = 0;
  for (let index = 0; index < expected.length; index++) diff |= expected.charCodeAt(index) ^ fields.v1.charCodeAt(index);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, "Method not allowed");
  try {
    const url = new URL(req.url);
    const body = await req.json().catch(() => ({}));
    const dataId = url.searchParams.get("data.id") || url.searchParams.get("id") || String(body?.data?.id || "");
    const topic = url.searchParams.get("type") || url.searchParams.get("topic") || String(body?.type || "");
    if (topic !== "payment") return reply(200, "ok");
    if (!await validSignature(req, dataId)) return reply(401, "Invalid signature");

    const sellerId = String(body?.user_id || "");
    if (!sellerId || !dataId) return reply(400, "Missing payment or seller");
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
    const response = await fetch("https://api.mercadopago.com/v1/payments/" + encodeURIComponent(dataId), {
      headers: { Authorization: "Bearer " + token, Accept: "application/json" },
    });
    const payment = await response.json().catch(() => ({}));
    if (!response.ok) return reply(502, "Payment lookup failed");
    if (String(payment.id) !== dataId) return reply(400, "Payment ID mismatch");
    if (String(payment.collector_id) !== sellerId) return reply(400, "Seller mismatch");
    if (String(payment.currency_id || "") !== "ARS") return reply(400, "Currency mismatch");
    if (typeof payment.live_mode !== "boolean" || Boolean(payment.live_mode) !== Boolean(tokenRow.live_mode)) return reply(400, "Environment mismatch");

    const orderId = String(payment.external_reference || "");
    if (!/^[0-9a-f-]{36}$/i.test(orderId)) return reply(400, "Invalid external reference");
    const { data: internalOrder, error: internalOrderError } = await admin.from("pedidos")
      .select("id,comercio_id,total,estado").eq("id", orderId).maybeSingle();
    if (internalOrderError || !internalOrder || internalOrder.comercio_id !== connection.comercio_id) return reply(404, "Internal order mismatch");

    const transactionAmount = Number(payment.transaction_amount);
    if (!Number.isFinite(transactionAmount) || Math.abs(transactionAmount - Number(internalOrder.total)) > 0.01) return reply(400, "Total mismatch");

    const status = String(payment.status || "");
    const paidAmount = Number(payment.transaction_details?.total_paid_amount ?? transactionAmount);
    let paymentState = "pendiente";
    if (status === "approved") {
      if (!Number.isFinite(paidAmount) || Math.abs(paidAmount - Number(internalOrder.total)) > 0.01) return reply(400, "Paid amount mismatch");
      paymentState = "aprobado";
    } else if (status === "rejected") {
      paymentState = "rechazado";
    } else if (status === "cancelled") {
      paymentState = "cancelado";
    } else if (status === "refunded" || status === "charged_back") {
      paymentState = "reembolsado";
    }

    const { data: commission, error: commissionError } = await admin.from("comisiones")
      .select("importe_comision").eq("pedido_id", orderId).maybeSingle();
    if (commissionError) throw commissionError;
    const { data: previousPayment, error: previousPaymentError } = await admin.from("pagos")
      .select("estado").eq("proveedor", "mercado_pago").eq("referencia_externa", String(payment.id)).maybeSingle();
    if (previousPaymentError) throw previousPaymentError;
    // No permitir que una notificación atrasada reabra un pago ya aprobado o reembolsado.
    if (previousPayment?.estado === "reembolsado" && paymentState !== "reembolsado") return reply(200, "ok");
    if (previousPayment?.estado === "aprobado" && paymentState !== "aprobado" && paymentState !== "reembolsado") return reply(200, "ok");

    const paymentIdempotency = "mp-payment-" + String(payment.id);
    const { error: saveError } = await admin.from("pagos").upsert({
      pedido_id: orderId,
      medio_pago: "mercado_pago",
      proveedor: "mercado_pago",
      estado: paymentState,
      importe: transactionAmount,
      moneda: "ARS",
      referencia_externa: String(payment.id),
      idempotencia: paymentIdempotency,
      fecha_confirmacion: status === "approved" ? (payment.date_approved || new Date().toISOString()) : null,
      datos_operativos: {
        payment_id: String(payment.id),
        payment_status: status,
        status_detail: payment.status_detail || null,
        live_mode: Boolean(payment.live_mode),
        marketplace_fee: commission ? Number(commission.importe_comision) : null,
        updated_at: new Date().toISOString(),
      },
      actualizado_at: new Date().toISOString(),
    }, { onConflict: "idempotencia" });
    if (saveError) throw saveError;

    if (status === "approved") {
      const { error } = await admin.from("pedidos").update({
        estado: "confirmado",
        actualizado_at: new Date().toISOString(),
      }).eq("id", orderId).in("estado", ["pendiente", "confirmado"]);
      if (error) throw error;
      if (commission) {
        const { error: commissionUpdateError } = await admin.from("comisiones").update({
          estado: "cobrada",
          importe_cobrado: Number(commission.importe_comision),
          actualizado_at: new Date().toISOString(),
        }).eq("pedido_id", orderId);
        if (commissionUpdateError) throw commissionUpdateError;
      }
    } else if (status === "refunded" || status === "charged_back") {
      const { error } = await admin.from("pedidos").update({
        estado: "reembolsado",
        actualizado_at: new Date().toISOString(),
      }).eq("id", orderId);
      if (error) throw error;
      const { error: commissionUpdateError } = await admin.from("comisiones").update({
        estado: "revertida",
        importe_cobrado: 0,
        actualizado_at: new Date().toISOString(),
      }).eq("pedido_id", orderId);
      if (commissionUpdateError) throw commissionUpdateError;
    }
    return reply(200, "ok");
  } catch (error) {
    console.error("mp-payment-webhook", error);
    return reply(500, "Webhook processing failed");
  }
});
