import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

async function fingerprint(req: Request): Promise<string | null> {
  const raw = req.headers.get("cf-connecting-ip")
    || req.headers.get("x-real-ip")
    || req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (!raw) return null;
  const bytes = new TextEncoder().encode(raw + "|" + (Deno.env.get("CHECKOUT_RATE_SALT") || "encontralo-ya-checkout-v1"));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { ok: false, mensaje: "Método no permitido" });

  try {
    const body = await req.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return reply(400, { ok: false, mensaje: "Solicitud inválida" });
    }

    // Campo trampa: los formularios automáticos suelen completarlo.
    if (typeof body.website === "string" && body.website.trim() !== "") {
      return reply(200, { ok: true, mensaje: "Solicitud recibida" });
    }

    const comercioId = String(body.comercio_id || "");
    const nombre = String(body.comprador_nombre || "").trim();
    const email = String(body.comprador_email || "").trim();
    const telefono = String(body.comprador_telefono || "").trim();
    const direccion = String(body.direccion_entrega || "").trim();
    const notas = String(body.notas || "").trim();
    const items = body.items;

    if (!/^[0-9a-f-]{36}$/i.test(comercioId)) return reply(400, { ok: false, mensaje: "Comercio inválido" });
    if (nombre.length < 2 || nombre.length > 120) return reply(400, { ok: false, mensaje: "Ingresá tu nombre" });
    if (telefono.length < 8 || telefono.length > 30) return reply(400, { ok: false, mensaje: "Ingresá un teléfono válido" });
    if (email.length > 160 || (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) return reply(400, { ok: false, mensaje: "Revisá el correo electrónico" });
    if (direccion.length > 300 || notas.length > 1000) return reply(400, { ok: false, mensaje: "Algún dato supera el largo permitido" });
    if (!Array.isArray(items) || items.length < 1 || items.length > 30) return reply(400, { ok: false, mensaje: "El carrito debe tener entre 1 y 30 productos" });

    const normalized = items.map((item: any) => ({
      producto_id: String(item?.producto_id || ""),
      cantidad: Number(item?.cantidad),
    }));
    if (normalized.some((item: any) => !/^[0-9a-f-]{36}$/i.test(item.producto_id) || !Number.isFinite(item.cantidad) || item.cantidad <= 0 || item.cantidad > 999)) {
      return reply(400, { ok: false, mensaje: "Revisá los productos y cantidades del carrito" });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) {
      console.error("Faltan variables de entorno de Supabase para checkout");
      return reply(503, { ok: false, mensaje: "El sistema de pedidos todavía no está disponible" });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const checkoutToken = Array.from(crypto.getRandomValues(new Uint8Array(32))).map((b) => b.toString(16).padStart(2, "0")).join("");
    const tokenDigest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(checkoutToken));
    const tokenHash = Array.from(new Uint8Array(tokenDigest)).map((b) => b.toString(16).padStart(2, "0")).join("");

    const { data, error } = await admin.rpc("crear_pedido_marketplace", {
      p_comercio_id: comercioId,
      p_items: normalized,
      p_comprador_nombre: nombre,
      p_comprador_email: email || null,
      p_comprador_telefono: telefono,
      p_direccion_entrega: direccion || null,
      p_notas: notas || null,
      p_huella: await fingerprint(req),
    });

    if (error) {
      console.error("Error al crear pedido:", error.message);
      const msg = error.message || "";
      if (/Demasiados intentos/i.test(msg)) return reply(429, { ok: false, mensaje: "Recibimos varios intentos desde esta conexión. Esperá unos minutos y volvé a intentar." });
      if (/no está disponible|requiere consultar precio|pesos argentinos|cantidad|pedido|nombre|teléfono|comercio|comisión|correo|dirección|notas|producto/i.test(msg)) {
        return reply(400, { ok: false, mensaje: msg });
      }
      return reply(500, { ok: false, mensaje: "No pudimos registrar el pedido. Intentá nuevamente." });
    }

    if (!data?.ok || !data?.pedido_id) return reply(500, { ok: false, mensaje: "No se recibió confirmación del pedido" });
    const { error: tokenError } = await admin.from("checkout_tokens_privado").upsert({
      pedido_id: data.pedido_id, token_hash: tokenHash,
      expira_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    }, { onConflict: "pedido_id" });
    if (tokenError) {
      console.error("No se pudo guardar la autorización privada del checkout:", tokenError.message);
      return reply(503, { ok: false, mensaje: "El pedido quedó registrado, pero no pudimos habilitar el pago seguro. Contactá al comercio antes de volver a intentarlo." });
    }
    return reply(200, { ...data, checkout_token: checkoutToken });
  } catch (error) {
    console.error("Error inesperado en checkout:", error);
    return reply(400, { ok: false, mensaje: "No pudimos interpretar los datos del pedido" });
  }
});
