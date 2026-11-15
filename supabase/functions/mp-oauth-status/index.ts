// Encontralo Ya — mp-oauth-status
// Indica si la cuenta de Mercado Pago de cada comercio del titular está
// vinculada. Nunca devuelve tokens ni credenciales: solo un booleano por
// comercio.
//
// Requiere en Supabase:
//   - La migración 20261115160000_estado_pedido_y_oauth_status.sql aplicada
//     (crea public.estado_oauth_comercios).
//   - El titular debe llamar con su sesión: Authorization: Bearer <token>.
//   - Variables automáticas del runtime: SUPABASE_URL,
//     SUPABASE_SERVICE_ROLE_KEY (o SUPABASE_SECRET_KEY).

const SUPABASE_URL =
  Deno.env.get("SUPABASE_URL") ?? Deno.env.get("SUPABASE") ?? "";
const PUBLIC_KEY =
  Deno.env.get("SUPABASE_ANON_KEY") ??
  Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
  "";
const SERVICE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
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

  if (!["GET", "POST"].includes(req.method)) {
    return json(405, { ok: false, mensaje: "Método no permitido." });
  }

  if (!SUPABASE_URL || !SERVICE_KEY || !PUBLIC_KEY) {
    return json(500, {
      ok: false,
      mensaje: "El servicio todavía no está configurado.",
    });
  }

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length < 20) {
    return json(401, {
      ok: false,
      mensaje: "Iniciá sesión en el panel para ver el estado de la conexión.",
    });
  }

  // Valida la sesión del titular con Supabase Auth.
  let userId = "";
  try {
    const userResp = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: {
        apikey: PUBLIC_KEY,
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
    return json(500, {
      ok: false,
      mensaje: "No pudimos validar tu sesión.",
    });
  }

  if (!userId) {
    return json(401, {
      ok: false,
      mensaje: "Tu sesión venció. Volvé a entrar al panel.",
    });
  }

  try {
    const rpcResp = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/estado_oauth_comercios`,
      {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_usuario_id: userId }),
      },
    );

    if (rpcResp.status === 404) {
      return json(503, {
        ok: false,
        mensaje: "La verificación de conexión todavía no está habilitada.",
      });
    }

    const data = await rpcResp.json().catch(() => null);
    if (!rpcResp.ok || !data || typeof data !== "object") {
      return json(500, {
        ok: false,
        mensaje: "No pudimos verificar la conexión de Mercado Pago.",
      });
    }

    return json(200, data);
  } catch {
    return json(500, {
      ok: false,
      mensaje: "No pudimos verificar la conexión de Mercado Pago.",
    });
  }
});
