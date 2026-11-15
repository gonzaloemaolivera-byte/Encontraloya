-- Encontralo Ya: estado de pedidos y conexión de Mercado Pago.
-- Usa exclusivamente las tablas reales del proyecto. No recorre esquemas ni
-- elimina registros fuera de la tabla exacta de credenciales OAuth.

BEGIN;

-- La comisión ya tiene una única fuente de verdad en esta tabla existente.
-- crear_pedido_marketplace lee porcentaje_comision (en porcentaje: 5 = 5%).
INSERT INTO public.configuracion_plataforma (id, porcentaje_comision)
VALUES (1, 5)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.obtener_comision_plataforma()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT coalesce(
    (SELECT porcentaje_comision / 100
     FROM public.configuracion_plataforma
     WHERE id = 1),
    0.05::numeric
  );
$function$;

CREATE OR REPLACE FUNCTION public.establecer_comision_plataforma(p_comision numeric)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF p_comision IS NULL OR p_comision < 0 OR p_comision > 0.5 THEN
    RAISE EXCEPTION 'La comisión debe estar entre 0 y 0.5 (0%% a 50%%).';
  END IF;

  UPDATE public.configuracion_plataforma
  SET porcentaje_comision = p_comision * 100,
      actualizado_at = pg_catalog.now()
  WHERE id = 1;

  IF NOT FOUND THEN
    INSERT INTO public.configuracion_plataforma (id, porcentaje_comision)
    VALUES (1, p_comision * 100);
  END IF;

  RETURN p_comision;
END;
$function$;

-- Comprueba el token de seguimiento únicamente contra el almacén real
-- checkout_tokens_privado. El valor guardado es SHA-256 hexadecimal.
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
  v_token_hash text;
  v_result jsonb;
BEGIN
  IF p_pedido_id IS NULL OR p_token IS NULL
     OR p_token !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false, 'mensaje', 'El código de seguimiento no es válido.'
    );
  END IF;

  v_token_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.lower(p_token), 'UTF8')),
    'hex'
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.checkout_tokens_privado t
    WHERE t.pedido_id = p_pedido_id
      AND t.token_hash = v_token_hash
      AND t.expira_at > pg_catalog.now()
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false, 'mensaje', 'No pudimos validar el código de seguimiento de este pedido.'
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
          'moneda', pg.moneda,
          'creado_at', pg.creado_at
        ) ORDER BY pg.creado_at
      )
      FROM public.pagos pg
      WHERE pg.pedido_id = p.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.pedidos p
  WHERE p.id = p_pedido_id;

  IF v_result IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false, 'mensaje', 'No encontramos el pedido.'
    );
  END IF;

  RETURN v_result;
END;
$function$;

-- Estado OAuth: consulta exclusivamente la tabla real de conexiones.
CREATE OR REPLACE FUNCTION public.estado_oauth_comercios(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_email_confirmado timestamptz;
  v_result jsonb;
BEGIN
  IF p_usuario_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false, 'mensaje', 'Iniciá sesión para ver el estado de la conexión.'
    );
  END IF;

  SELECT u.email_confirmed_at
  INTO v_email_confirmado
  FROM auth.users u
  WHERE u.id = p_usuario_id;

  IF v_email_confirmado IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false, 'mensaje', 'Confirmá tu correo para ver el estado de la conexión.'
    );
  END IF;

  SELECT coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'nombre', c.nombre,
        'conectado', coalesce(mp.estado = 'conectado', false)
      ) ORDER BY c.nombre
    ),
    '[]'::jsonb
  )
  INTO v_result
  FROM public.comercios c
  LEFT JOIN public.conexiones_mercado_pago mp
    ON mp.comercio_id = c.id
  WHERE c.propietario_id = p_usuario_id;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'comercios', v_result);
END;
$function$;

-- Desconexión: elimina exclusivamente las credenciales OAuth de ese comercio
-- y actualiza su indicador. No toca pedidos, productos, reclamos ni otras tablas.
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
  v_es_titular boolean;
  v_filas bigint := 0;
BEGIN
  IF p_comercio_id IS NULL OR p_usuario_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Faltan datos.');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.comercios c
    WHERE c.id = p_comercio_id
      AND c.propietario_id = p_usuario_id
  ) INTO v_es_titular;

  IF NOT v_es_titular THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Solo el titular del comercio puede desconectar la cuenta.'
    );
  END IF;

  DELETE FROM public.mercado_pago_tokens_privado
  WHERE comercio_id = p_comercio_id;
  GET DIAGNOSTICS v_filas = ROW_COUNT;

  UPDATE public.conexiones_mercado_pago
  SET estado = 'desconectado',
      desconectado_at = pg_catalog.now(),
      actualizado_at = pg_catalog.now()
  WHERE comercio_id = p_comercio_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'mensaje', 'La cuenta de Mercado Pago quedó desconectada. Podés volver a vincularla cuando quieras.',
    'desconectado', v_filas > 0
  );
END;
$function$;

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
