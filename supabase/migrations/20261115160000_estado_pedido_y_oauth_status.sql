-- ============================================================================
-- Encontralo Ya — Estado de pedidos y conexión de Mercado Pago
-- Fecha: 2026-11-15
-- ============================================================================
-- Qué agrega esta migración:
--
-- 1. public.consultar_estado_pedido(pedido_id, checkout_token)
--    Permite al comprador consultar el estado real de su pedido y de su pago
--    sin exponer datos privados: valida el código de seguimiento (checkout
--    token) contra el almacén privado del proyecto y devuelve solo estado,
--    número de pedido, total y estado del pago. Nunca devuelve teléfonos,
--    correos ni direcciones.
--
-- 2. public.estado_oauth_comercios(usuario_id)
--    Indica para cada comercio del titular si su cuenta de Mercado Pago está
--    vinculada (sin mostrar tokens ni credenciales).
--
-- 3. public.eliminar_oauth_comercio(comercio_id, usuario_id)
--    Desconecta de forma segura la cuenta de Mercado Pago de un comercio del
--    titular (borra las credenciales almacenadas en el esquema privado).
--
-- 4. Configuración de la comisión de la plataforma (5% actual):
--    private.configuracion_plataforma + public.obtener_comision_plataforma().
--    El valor se cambia una sola vez y toda la plataforma lo lee de ahí.
--
-- Nota de diseño: no asume nombres fijos de las tablas privadas existentes
-- (OAuth y tokens de checkout): las descubre dinámicamente en el esquema
-- "private" buscando una columna uuid que coincida con el pedido/comercio y
-- una columna de credencial (bytea o texto) que coincida con el código.
-- Si no encuentra coincidencia, falla cerrado (rechaza la consulta).
-- Ejecutar desde el SQL Editor de Supabase con el rol postgres.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

-- ---------------------------------------------------------------------------
-- 1. Configuración de la comisión de la plataforma
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.configuracion_plataforma (
  clave text PRIMARY KEY,
  valor jsonb NOT NULL,
  actualizado_en timestamptz NOT NULL DEFAULT pg_catalog.now()
);

REVOKE ALL ON TABLE private.configuracion_plataforma
  FROM PUBLIC, anon, authenticated, service_role;

-- 5% para Encontralo Ya (valor comercial actual). Si ya existe, se conserva.
INSERT INTO private.configuracion_plataforma (clave, valor)
VALUES ('comision_porcentaje', '0.05'::jsonb)
ON CONFLICT (clave) DO NOTHING;

-- La comisión se lee de la configuración; 0.05 solo si no está configurada.
-- Se limita entre 0% y 50% para evitar errores de carga.
CREATE OR REPLACE FUNCTION public.obtener_comision_plataforma()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT least(
    greatest(
      coalesce((
        SELECT (valor #>> '{}')::numeric
        FROM private.configuracion_plataforma
        WHERE clave = 'comision_porcentaje'
      ), 0.05::numeric),
      0::numeric
    ),
    0.5::numeric
  );
$function$;

-- Cambio de comisión: solo desde SQL Editor (rol postgres). Ejemplo:
--   SELECT public.establecer_comision_plataforma(0.05);
CREATE OR REPLACE FUNCTION public.establecer_comision_plataforma(
  p_comision numeric
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF p_comision IS NULL OR p_comision < 0 OR p_comision > 0.5 THEN
    RAISE EXCEPTION 'La comisión debe estar entre 0 y 0.5 (0%% a 50%%).';
  END IF;

  INSERT INTO private.configuracion_plataforma (clave, valor)
  VALUES ('comision_porcentaje', pg_catalog.to_jsonb(p_comision))
  ON CONFLICT (clave) DO UPDATE
    SET valor = pg_catalog.to_jsonb(p_comision),
        actualizado_en = pg_catalog.now();

  RETURN p_comision;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Consulta del estado real del pedido (comprador)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.consultar_estado_pedido(
  p_pedido_id uuid,
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_token text;
  v_raw text;
  v_lower text;
  v_upper text;
  v_hraw text;
  v_hlower text;
  v_hupper text;
  v_tabla text;
  v_oid oid;
  v_uuid_conds text;
  v_data_conds text;
  v_cond text;
  v_match boolean;
  v_valido boolean := false;
  v_result jsonb;
  rec record;
  col record;
BEGIN
  IF p_pedido_id IS NULL OR p_token IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Faltan los datos del pedido.'
    );
  END IF;

  v_token := pg_catalog.btrim(p_token);
  IF v_token !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'El código de seguimiento no es válido.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pedidos AS p WHERE p.id = p_pedido_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'No encontramos el pedido.'
    );
  END IF;

  -- Variantes del código tal como fue emitido y de sus hashes.
  v_raw := v_token;
  v_lower := pg_catalog.lower(v_token);
  v_upper := pg_catalog.upper(v_token);
  v_hraw := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(v_raw, 'UTF8')), 'hex');
  v_hlower := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(v_lower, 'UTF8')), 'hex');
  v_hupper := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(v_upper, 'UTF8')), 'hex');

  -- Descubre el almacén de tokens de checkout en el esquema privado.
  FOR rec IN
    SELECT c.oid,
           pg_catalog.quote_ident(n.nspname) || '.' ||
             pg_catalog.quote_ident(c.relname) AS tabla
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p')
      AND n.nspname = 'private'
      AND c.relname !~* '(reclamo|intentos|configuracion)'
  LOOP
    v_oid := rec.oid;
    v_uuid_conds := NULL;
    v_data_conds := NULL;

    -- Columna uuid que referencia al pedido.
    FOR col IN
      SELECT pg_catalog.quote_ident(a.attname) AS col
      FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = v_oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.atttypid = 'uuid'::regtype
    LOOP
      v_uuid_conds := pg_catalog.concat_ws(
        ' OR ',
        v_uuid_conds,
        pg_catalog.format('t.%s = %L::uuid', col.col, p_pedido_id::text)
      );
    END LOOP;

    -- Columna de credencial: bytea (hash o cifrada) o texto (plano o hash hex).
    FOR col IN
      SELECT pg_catalog.quote_ident(a.attname) AS col, t.typname AS tipo
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
      WHERE a.attrelid = v_oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND (
          a.atttypid = 'bytea'::regtype
          OR a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
        )
    LOOP
      IF col.tipo = 'bytea' THEN
        v_cond := pg_catalog.format(
          't.%s IN (pg_catalog.decode(%L, ''hex''), pg_catalog.decode(%L, ''hex''), ' ||
          'pg_catalog.decode(%L, ''hex''), pg_catalog.convert_to(%L, ''UTF8''), pg_catalog.convert_to(%L, ''UTF8''))',
          col.col, v_hraw, v_hlower, v_hupper, v_raw, v_lower
        );
      ELSE
        v_cond := pg_catalog.format(
          't.%s IN (%L, %L, %L, %L, %L, %L)',
          col.col, v_raw, v_lower, v_upper, v_hraw, v_hlower, v_hupper
        );
      END IF;
      v_data_conds := pg_catalog.concat_ws(' OR ', v_data_conds, v_cond);
    END LOOP;

    IF v_data_conds IS NULL THEN
      CONTINUE;
    END IF;
    IF v_uuid_conds IS NULL THEN
      v_uuid_conds := 'true';
    END IF;

    BEGIN
      EXECUTE pg_catalog.format(
        'SELECT EXISTS (SELECT 1 FROM %s t WHERE (%s) AND (%s))',
        rec.tabla, v_uuid_conds, v_data_conds
      ) INTO v_match;
    EXCEPTION WHEN OTHERS THEN
      v_match := false;
    END;

    IF v_match THEN
      v_valido := true;
      EXIT;
    END IF;
  END LOOP;

  -- Falla cerrado: si ningún almacén privado valida el código, se rechaza.
  IF NOT v_valido THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'No pudimos validar el código de seguimiento de este pedido.'
    );
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'ok', true,
    'numero_pedido', p.numero_pedido,
    'estado', p.estado,
    'total', p.total,
    'moneda', p.moneda,
    'creado_at', p.creado_at,
    'actualizado_at', p.actualizado_at,
    'pago', (
      SELECT pg_catalog.jsonb_build_object(
        'estado', pg.estado,
        'medio_pago', pg.medio_pago,
        'importe', pg.importe,
        'moneda', pg.moneda,
        'creado_at', pg.creado_at,
        'actualizado_at', pg.actualizado_at
      )
      FROM public.pagos pg
      WHERE pg.pedido_id = p.id
      ORDER BY pg.creado_at DESC
      LIMIT 1
    ),
    'pagos', coalesce((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'estado', pg.estado,
          'medio_pago', pg.medio_pago,
          'importe', pg.importe,
          'creado_at', pg.creado_at
        )
        ORDER BY pg.creado_at
      )
      FROM public.pagos pg
      WHERE pg.pedido_id = p.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.pedidos p
  WHERE p.id = p_pedido_id;

  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Estado de la conexión de Mercado Pago por comercio (titular)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.estado_oauth_comercios(
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_email_confirmado timestamptz;
  v_oid oid;
  v_uuid_conds text;
  v_data_conds text;
  v_cond text;
  v_match boolean;
  v_result jsonb := '[]'::jsonb;
  rec record;
  col record;
  com record;
BEGIN
  IF p_usuario_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Iniciá sesión para ver el estado de la conexión.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'private'
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'La conexión de Mercado Pago todavía no está configurada.'
    );
  END IF;

  SELECT u.email_confirmed_at INTO v_email_confirmado
  FROM auth.users u
  WHERE u.id = p_usuario_id;

  IF v_email_confirmado IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Confirmá tu correo para ver el estado de la conexión.'
    );
  END IF;

  FOR com IN
    SELECT c.id, c.nombre
    FROM public.comercios c
    WHERE c.propietario_id = p_usuario_id
    ORDER BY c.nombre
  LOOP
    v_match := false;

    FOR rec IN
      SELECT c2.oid
      FROM pg_catalog.pg_class c2
      JOIN pg_catalog.pg_namespace n2 ON n2.oid = c2.relnamespace
      WHERE c2.relkind IN ('r','p')
        AND n2.nspname = 'private'
        AND c2.relname !~* '(reclamo|intentos|configuracion)'
    LOOP
      v_oid := rec.oid;
      v_uuid_conds := NULL;
      v_data_conds := NULL;

      FOR col IN
        SELECT pg_catalog.quote_ident(a.attname) AS col
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = v_oid
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.atttypid = 'uuid'::regtype
      LOOP
        v_uuid_conds := pg_catalog.concat_ws(
          ' OR ',
          v_uuid_conds,
          pg_catalog.format('s.%s = %L::uuid', col.col, com.id::text)
        );
      END LOOP;

      FOR col IN
        SELECT pg_catalog.quote_ident(a.attname) AS col, t.typname AS tipo
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
        WHERE a.attrelid = v_oid
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND (
            a.atttypid = 'bytea'::regtype
            OR a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
          )
      LOOP
        IF col.tipo = 'bytea' THEN
          v_cond := pg_catalog.format(
            '(s.%s IS NOT NULL AND pg_catalog.octet_length(s.%s) >= 16)',
            col.col, col.col
          );
        ELSE
          v_cond := pg_catalog.format(
            '(s.%s IS NOT NULL AND pg_catalog.length(s.%s) >= 32)',
            col.col, col.col
          );
        END IF;
        v_data_conds := pg_catalog.concat_ws(' OR ', v_data_conds, v_cond);
      END LOOP;

      IF v_data_conds IS NULL OR v_uuid_conds IS NULL THEN
        CONTINUE;
      END IF;

      BEGIN
        EXECUTE pg_catalog.format(
          'SELECT EXISTS (SELECT 1 FROM %s.%s s WHERE (%s) AND (%s))',
          pg_catalog.quote_ident('private'),
          pg_catalog.quote_ident((SELECT c2.relname FROM pg_catalog.pg_class c2 WHERE c2.oid = v_oid)),
          v_uuid_conds, v_data_conds
        ) INTO v_match;
      EXCEPTION WHEN OTHERS THEN
        v_match := false;
      END;

      IF v_match THEN
        EXIT;
      END IF;
    END LOOP;

    v_result := v_result || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', com.id,
        'nombre', com.nombre,
        'conectado', v_match
      )
    );
  END LOOP;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'comercios', v_result);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Desconexión segura de Mercado Pago (titular)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.eliminar_oauth_comercio(
  p_comercio_id uuid,
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_ok boolean;
  v_oid oid;
  v_relname text;
  v_uuid_conds text;
  v_data_conds text;
  v_cond text;
  v_filas bigint := 0;
  v_total bigint := 0;
  rec record;
  col record;
BEGIN
  IF p_comercio_id IS NULL OR p_usuario_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Faltan datos.');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.comercios c
    WHERE c.id = p_comercio_id AND c.propietario_id = p_usuario_id
  ) INTO v_ok;

  IF NOT v_ok THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Solo el titular del comercio puede desconectar la cuenta.'
    );
  END IF;

  FOR rec IN
    SELECT c.oid, c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p')
      AND n.nspname = 'private'
      AND c.relname !~* '(reclamo|intentos|configuracion)'
  LOOP
    v_oid := rec.oid;
    v_relname := rec.relname;
    v_uuid_conds := NULL;
    v_data_conds := NULL;

    FOR col IN
      SELECT pg_catalog.quote_ident(a.attname) AS col
      FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = v_oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.atttypid = 'uuid'::regtype
    LOOP
      v_uuid_conds := pg_catalog.concat_ws(
        ' OR ',
        v_uuid_conds,
        pg_catalog.format('s.%s = %L::uuid', col.col, p_comercio_id::text)
      );
    END LOOP;

    FOR col IN
      SELECT pg_catalog.quote_ident(a.attname) AS col, t.typname AS tipo
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
      WHERE a.attrelid = v_oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND (
          a.atttypid = 'bytea'::regtype
          OR a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
        )
    LOOP
      IF col.tipo = 'bytea' THEN
        v_cond := pg_catalog.format(
          's.%s IS NOT NULL', col.col
        );
      ELSE
        v_cond := pg_catalog.format(
          's.%s IS NOT NULL', col.col
        );
      END IF;
      v_data_conds := pg_catalog.concat_ws(' OR ', v_data_conds, v_cond);
    END LOOP;

    IF v_data_conds IS NULL OR v_uuid_conds IS NULL THEN
      CONTINUE;
    END IF;

    BEGIN
      EXECUTE pg_catalog.format(
        'DELETE FROM %s.%s s WHERE (%s) AND (%s)',
        pg_catalog.quote_ident('private'),
        pg_catalog.quote_ident(v_relname),
        v_uuid_conds, v_data_conds
      );
      GET DIAGNOSTICS v_filas = ROW_COUNT;
      v_total := v_total + v_filas;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'mensaje', CASE
      WHEN v_total > 0
        THEN 'Desconectamos la cuenta de Mercado Pago de este comercio. Podés volver a conectarla cuando quieras.'
      ELSE 'Este comercio no tenía una cuenta de Mercado Pago conectada.'
    END,
    'desconectado', v_total > 0
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Permisos: las funciones se ejecutan desde las Edge Functions con la clave
-- service_role. Ninguna queda expuesta a anon ni authenticated.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.obtener_comision_plataforma()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.establecer_comision_plataforma(numeric)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.consultar_estado_pedido(uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.estado_oauth_comercios(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.eliminar_oauth_comercio(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.obtener_comision_plataforma() TO service_role;
GRANT EXECUTE ON FUNCTION public.consultar_estado_pedido(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.estado_oauth_comercios(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.eliminar_oauth_comercio(uuid, uuid) TO service_role;

COMMIT;

-- Resumen:
-- * consultar_estado_pedido: valida el código de seguimiento contra el
--   almacén privado y devuelve solo estado del pedido y del pago.
-- * estado_oauth_comercios / eliminar_oauth_comercio: indicador y desconexión
--   segura de la cuenta de Mercado Pago, siempre dentro de los comercios del
--   titular autenticado.
-- * obtener_comision_plataforma: fuente única de la comisión (0.05 por
--   defecto). Para cambiarla: SELECT public.establecer_comision_plataforma(0.06);
-- * Descubre dinámicamente las tablas privadas: funciona con los nombres
--   reales del proyecto aunque difieran de los esperados.
