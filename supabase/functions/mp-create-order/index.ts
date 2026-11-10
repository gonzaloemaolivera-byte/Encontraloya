import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { ok: false, mensaje: "Método no permitido" });
  try {
    const body = await req.json().catch(() => ({}));
    const pedidoId = String(body?.pedido_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(pedidoId)) {
      return reply(400, { ok: false, mensaje: "Pedido inválido." });
    }

    const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: order, error: orderError } = await admin.from("pedidos")
      .select("id,comercio_id,estado,total,moneda,comprador_email,pedido_productos(nombre_producto,cantidad,precio_unitario,subtotal)")
      .eq("id", pedidoId).maybeSingle();
    if (orderError || !order) return reply(404, { ok: false, mensaje: "No encontramos el pedido." });
    if (order.estado !== "pendiente") {
      return reply(409, { ok: false, mensaje: "Este pedido ya no está pendiente de pago." });
    }
    const total = Number(order.total);
    if (order.moneda !== "ARS" || !Number.isFinite(total) || total <= 0) {
      return reply(400, { ok: false, mensaje: "El pedido no tiene un total válido en pesos argentinos." });
    }

    const { data: existing, error: existingError } = await admin.from("pagos")
      .select("estado,datos_operativos").eq("pedido_id", pedidoId)
      .eq("proveedor", "mercado_pago").maybeSingle();
    if (existingError) throw existingError;
    const oldUrl = existing?.datos_operativos?.checkout_url;
    if (existing?.estado === "pendiente" && typeof oldUrl === "string" && oldUrl.startsWith("https://")) {
      return reply(200, { ok: true, checkout_url: oldUrl, reutilizado: true });
    }

    const { data: connection, error: connectionError } = await admin.from("conexiones_mercado_pago")
      .select("estado,usuario_mercado_pago_id").eq("comercio_id", order.comercio_id).maybeSingle();
    if (connectionError || connection?.estado !== "conectado") {
      return reply(409, { ok: false, mensaje: "Este comercio todavía no vinculó su cuenta de Mercado Pago." });
    }
    const { data: tokenRow, error: tokenError } = await admin.from("mercado_pago_tokens_privado")
      .select("*").eq("comercio_id", order.comercio_id).maybeSingle();
    if (tokenError || !tokenRow) {
      return reply(409, { ok: false, mensaje: "La conexión de Mercado Pago necesita volver a autorizarse." });
    }
    const { data: commission, error: commissionError } = await admin.from("comisiones")
      .select("porcentaje,base_calculo,importe_comision").eq("pedido_id", pedidoId).maybeSingle();
    if (commissionError || !commission) {
      return reply(500, { ok: false, mensaje: "No pudimos calcular la comisión de la plataforma." });
    }
    const fee = Number(commission.importe_comision);
    if (!Number.isFinite(fee) || fee < 0 || fee >= total) {
      return reply(400, { ok: false, mensaje: "La comisión calculada no es válida para este pedido." });
    }

    const token = await sellerToken(admin, tokenRow);
    const lines = Array.isArray(order.pedido_productos) ? order.pedido_productos : [];
    const items = lines.map((item: any) => {
      const subtotal = Number(item.subtotal);
      const quantity = Number(item.cantidad);
      const title = String(item.nombre_producto || "Producto").slice(0, 180);
      if (!Number.isFinite(subtotal) || subtotal <= 0 || !Number.isFinite(quantity) || quantity <= 0) {
        throw new Error("El pedido contiene un producto con cantidad o importe inválido");
      }
      // La order conserva el importe exacto de cada línea; el detalle de cantidad
      // queda expresado en el título para admitir cantidades fraccionarias.
      return {
        title: (quantity === 1 ? title : title + " x " + String(quantity)).slice(0, 250),
        quantity: 1,
        unit_price: subtotal.toFixed(2),
      };
    });
    if (!items.length || Math.abs(items.reduce((sum: number, item: any) => sum + Number(item.unit_price), 0) - total) > 0.01) {
      return reply(400, { ok: false, mensaje: "Los productos no coinciden con el total del pedido." });
    }

    const site = env("SITE_URL").replace(/\/$/, "");
    const orderPayload: Record<string, unknown> = {
      type: "online",
      processing_mode: "manual",
      total_amount: total.toFixed(2),
      external_reference: pedidoId,
      marketplace_fee: fee.toFixed(2),
      items,
      config: {
        online: {
          success_url: site + "/index.html?pago=exito&pedido=" + encodeURIComponent(pedidoId),
          pending_url: site + "/index.html?pago=pendiente&pedido=" + encodeURIComponent(pedidoId),
          failure_url: site + "/index.html?pago=error&pedido=" + encodeURIComponent(pedidoId),
          auto_return: "approved",
        },
      },
    };
    if (typeof order.comprador_email === "string" && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(order.comprador_email)) {
      orderPayload.payer = { email: order.comprador_email };
    }

    const idempotencyKey = "mp-order-" + pedidoId;
    const response = await fetch("https://api.mercadopago.com/v1/orders", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + token,
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify(orderPayload),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.id || !data.checkout_url) {
      console.error("Order creation failed:", response.status, data.message || data.error || "sin detalle");
      return reply(502, { ok: false, mensaje: "Mercado Pago no pudo crear el checkout. Volvé a intentar." });
    }

    const checkoutUrl = String(data.checkout_url);
    if (!checkoutUrl.startsWith("https://")) {
      return reply(502, { ok: false, mensaje: "Mercado Pago devolvió una dirección de pago inválida." });
    }
    const { error: paymentError } = await admin.from("pagos").upsert({
      pedido_id: pedidoId,
      medio_pago: "mercado_pago",
      proveedor: "mercado_pago",
      estado: "pendiente",
      importe: total,
      moneda: "ARS",
      referencia_externa: String(data.id),
      idempotencia: idempotencyKey,
      datos_operativos: {
        order_id: String(data.id),
        checkout_url: checkoutUrl,
        live_mode: Boolean(tokenRow.live_mode),
        marketplace_fee: fee,
        created_at: new Date().toISOString(),
      },
      actualizado_at: new Date().toISOString(),
    }, { onConflict: "idempotencia" });
    if (paymentError) throw paymentError;

    return reply(200, { ok: true, checkout_url: checkoutUrl, order_id: String(data.id) });
  } catch (error) {
    console.error("mp-create-order", error);
    return reply(500, { ok: false, mensaje: "No pudimos preparar el pago. Intentá nuevamente." });
  }
});
