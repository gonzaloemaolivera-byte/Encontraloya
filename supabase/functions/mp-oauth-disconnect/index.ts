// Encontralo Ya — mp-oauth-disconnect
// Desconecta de forma segura la cuenta de Mercado Pago de un comercio del
// titular: borra las credenciales almacenadas en el esquema privado.
// No devuelve tokens ni credenciales.
//
// Requiere en Supabase:
//   - La migración 20261115160000_estado_pedido_y_oauth_status.sql aplicada
//     (crea public.eliminar_oauth_comercio).
//   - El titular debe llamar con su sesión: Authorization: Bearer <token>.
//   - Variables automáticas del runtime: SUPABASE_URL,
//     SUPABASE_SERVICE_ROLE_KEY (o SUPABASE_SECRET_KEY).

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
      mensaje: "El servicio todavía no está configurado.",
    });
  }

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length < 20) {
    return json(401, {
      ok: false,
      mensaje: "Iniciá sesión en el panel para desconectar la cuenta.",
    });
  }

  let body;
  try {
    body = await req.json();
  } catch {
    return json(400, { ok: false, mensaje: "Solicitud inválida." });
  }

  const comercioId = typeof body?.comercio_id === "string" ? body.comercio_id.trim() : "";
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(comercioId)
  ) {
    return json(400, { ok: false, mensaje: "Comercio inválido." });
  }

  // Valida la sesión del titular con Supabase Auth.
  let userId = "";
  try {
    const userResp = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: {
        apikey: SERVICE_KEY,
        Authorization: authorization,
      },
    });
    if (!userResp.ok) {
      return json(401, {
        ok: false,
        mensaje: "Tu sesión venció. Volvé a entrar al panel.",
      });
    }
    const user = await userResp.json();
    userId = user?.id ?? "";
  } catch {
    return json(500, { ok: false, mensaje: "No pudimos validar tu sesión." });
  }

  if (!userId) {
    return json(401, {
      ok: false,
      mensaje: "Tu sesión venció. Volvé a entrar al panel.",
    });
  }

  try {
    const rpcResp = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/eliminar_oauth_comercio`,
      {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_comercio_id: comercioId,
          p_usuario_id: userId,
        }),
      },
    );

    if (rpcResp.status === 404) {
      return json(503, {
        ok: false,
        mensaje: "La desconexión todavía no está habilitada en el servidor.",
      });
    }

    const data = await rpcResp.json().catch(() => null);
    if (!rpcResp.ok || !data || typeof data !== "object") {
      return json(500, {
        ok: false,
        mensaje: "No pudimos desconectar la cuenta de Mercado Pago.",
      });
    }

    return json(200, data);
  } catch {
    return json(500, {
      ok: false,
      mensaje: "No pudimos desconectar la cuenta de Mercado Pago.",
    });
  }
});
