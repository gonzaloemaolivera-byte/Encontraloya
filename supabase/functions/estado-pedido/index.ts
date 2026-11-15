// Encontralo Ya — estado-pedido
// Consulta el estado real de un pedido y de su pago.
// El comprador necesita el identificador del pedido y su código de
// seguimiento (checkout_token) que recibió al crear el pedido.
// No expone datos personales, tokens ni información de otros pedidos.
//
// Requiere en Supabase:
//   - La migración 20261115160000_estado_pedido_y_oauth_status.sql aplicada
//     (crea public.consultar_estado_pedido).
//   - Variables de entorno automáticas del runtime de Supabase:
//     SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY (o SUPABASE_SECRET_KEY).

const SUPABASE_URL =
  Deno.env.get("SUPABASE_URL") ?? Deno.env.get("SUPABASE") ?? "";
const SERVICE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "apikey, authorization, content-type, x-client-info, prefer",
  "Access-Control-Max-Age": "86400",
};

// Límite sencillo por pedido: evita que un cliente martille la consulta.
const consultasRecientes = new Map();
const LIMITE = 30; // máximo de consultas
const VENTANA_MS = 60_000; // por minuto

function permitir(pedidoId: string): boolean {
  const ahora = Date.now();
  const registro = consultasRecientes.get(pedidoId);
  if (!registro || ahora - registro.inicio > VENTANA_MS) {
    consultasRecientes.set(pedidoId, { inicio: ahora, cantidad: 1 });
    return true;
  }
  registro.cantidad += 1;
  if (registro.cantidad > LIMITE) return false;
  return true;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return json(405, { ok: false, mensaje: "Método no permitido." });
  }

  if (!SUPABASE_URL || !SERVICE_KEY) {
    return json(500, {
      ok: false,
      mensaje: "El servicio de consultas todavía no está configurado.",
    });
  }

  let body;
  try {
    body = await req.json();
  } catch {
    return json(400, { ok: false, mensaje: "Solicitud inválida." });
  }

  const pedidoId = typeof body?.pedido_id === "string" ? body.pedido_id.trim() : "";
  const token = typeof body?.checkout_token === "string" ? body.checkout_token.trim() : "";

  if (!pedidoId || !token) {
    return json(400, {
      ok: false,
      mensaje: "Faltan el identificador del pedido o el código de seguimiento.",
    });
  }

  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(pedidoId)
  ) {
    return json(400, {
      ok: false,
      mensaje: "El identificador del pedido no es válido.",
    });
  }

  if (!/^[0-9a-fA-F]{64}$/.test(token)) {
    return json(400, {
      ok: false,
      mensaje: "El código de seguimiento no es válido.",
    });
  }

  if (!permitir(pedidoId.toLowerCase())) {
    return json(429, {
      ok: false,
      mensaje: "Se alcanzó el límite de consultas por ahora. Probá en un minuto.",
    });
  }

  try {
    const rpcResp = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/consultar_estado_pedido`,
      {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_pedido_id: pedidoId,
          p_token: token,
        }),
      },
    );

    const data = await rpcResp.json().catch(() => null);

    if (rpcResp.status === 404) {
      return json(503, {
        ok: false,
        mensaje:
          "La consulta de estados todavía no está habilitada en el servidor.",
      });
    }

    if (!rpcResp.ok || !data || typeof data !== "object") {
      return json(500, {
        ok: false,
        mensaje: "No pudimos consultar el estado del pedido.",
      });
    }

    return json(200, data);
  } catch (_error) {
    return json(500, {
      ok: false,
      mensaje: "No pudimos consultar el estado del pedido.",
    });
  }
});
