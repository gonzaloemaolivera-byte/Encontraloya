-- Verificaciones de la migración 20261115160000_estado_pedido_y_oauth_status.sql
-- Se ejecuta sobre el esquema de prueba (supabase/tests/fixtures/
-- esquema-estado-pedido-prueba.sql) en una base descartable de CI.
-- Cada verificación falla con un mensaje claro si el comportamiento no es
-- el esperado.

-- ============================================================================
-- 1. consultar_estado_pedido
-- ============================================================================
DO $$
DECLARE
  v_pedido uuid := '00000000-0000-4000-8000-000000000201';
  v_token text := repeat('a', 64);
  v_resp jsonb;
BEGIN
  -- 1.1 Token válido devuelve el estado y el pago.
  v_resp := public.consultar_estado_pedido(v_pedido, v_token);
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FALLO 1.1: el token válido debe autorizar la consulta (%).', v_resp->>'mensaje';
  END IF;
  IF v_resp->>'numero_pedido' <> '9001' THEN
    RAISE EXCEPTION 'FALLO 1.1b: número de pedido incorrecto (%).', v_resp->>'numero_pedido';
  END IF;
  IF (v_resp->'pago'->>'estado') <> 'pendiente' THEN
    RAISE EXCEPTION 'FALLO 1.1c: estado del pago incorrecto (%).', v_resp->'pago'->>'estado';
  END IF;

  -- 1.2 El token también funciona en mayúsculas.
  v_resp := public.consultar_estado_pedido(v_pedido, upper(v_token));
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FALLO 1.2: el token en mayúsculas debe autorizar la consulta.';
  END IF;

  -- 1.3 Formato inválido: rechazo.
  v_resp := public.consultar_estado_pedido(v_pedido, 'corto');
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 1.3: un token con formato inválido debe rechazarse.';
  END IF;

  -- 1.4 Token correcto en formato pero equivocado: rechazo.
  v_resp := public.consultar_estado_pedido(v_pedido, repeat('b', 64));
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 1.4: un token incorrecto debe rechazarse.';
  END IF;

  -- 1.5 Pedido inexistente: rechazo.
  v_resp := public.consultar_estado_pedido('00000000-0000-4000-8000-000000000299', v_token);
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 1.5: un pedido inexistente debe rechazarse.';
  END IF;

  -- 1.6 El comprador no recibe sus datos personales en la respuesta.
  v_resp := public.consultar_estado_pedido(v_pedido, v_token);
  IF v_resp::text ~* 'comprador|Comprador|comprador@example' THEN
    RAISE EXCEPTION 'FALLO 1.6: la respuesta no debe contener datos personales del comprador.';
  END IF;

  -- 1.7 El token de un código de reclamo no autoriza nada.
  v_resp := public.consultar_estado_pedido(v_pedido, repeat('z',64));
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 1.7: el hash de un código de reclamo no debe autorizar la consulta.';
  END IF;
END $;

-- 1.7b Un token vencido no debe autorizar la consulta.
UPDATE public.checkout_tokens_privado
SET expira_at = now() - interval '1 minute'
WHERE pedido_id = '00000000-0000-4000-8000-000000000201';
DO $
DECLARE
  v_resp jsonb;
BEGIN
  v_resp := public.consultar_estado_pedido(
    '00000000-0000-4000-8000-000000000201', repeat('a',64)
  );
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 1.7b: un token vencido debe rechazarse.';
  END IF;
END $;
UPDATE public.checkout_tokens_privado
SET expira_at = now() + interval '1 day'
WHERE pedido_id = '00000000-0000-4000-8000-000000000201';

-- 1.8 El pago aprobado se refleja en la consulta.
UPDATE public.pagos SET estado = 'aprobado' WHERE pedido_id = '00000000-0000-4000-8000-000000000201';
DO $$
DECLARE
  v_resp jsonb;
BEGIN
  v_resp := public.consultar_estado_pedido('00000000-0000-4000-8000-000000000201', repeat('a', 64));
  IF (v_resp->'pago'->>'estado') <> 'aprobado' THEN
    RAISE EXCEPTION 'FALLO 1.8: el pago aprobado debe verse en la consulta.';
  END IF;
END $$;

-- ============================================================================
-- 2. estado_oauth_comercios
-- ============================================================================
DO $$
DECLARE
  v_resp jsonb;
  v_item jsonb;
  v_conectado_101 boolean;
  v_conectado_102 boolean;
BEGIN
  -- 2.1 Titular con un comercio conectado y otro sin conectar.
  v_resp := public.estado_oauth_comercios('00000000-0000-4000-8000-000000000001');
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FALLO 2.1: la consulta del titular debe funcionar.';
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_resp->'comercios') LOOP
    IF v_item->>'id' = '00000000-0000-4000-8000-000000000101' THEN
      v_conectado_101 := (v_item->>'conectado') = 'true';
    ELSIF v_item->>'id' = '00000000-0000-4000-8000-000000000102' THEN
      v_conectado_102 := (v_item->>'conectado') = 'true';
    END IF;
  END LOOP;
  IF v_conectado_101 IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'FALLO 2.1b: el comercio con OAuth vinculado debe figurar conectado.';
  END IF;
  IF v_conectado_102 IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'FALLO 2.1c: el comercio sin vincular no debe figurar conectado.';
  END IF;

  -- 2.2 Usuario sin comercios: lista vacía.
  v_resp := public.estado_oauth_comercios('00000000-0000-4000-8000-000000000002');
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' OR jsonb_array_length(v_resp->'comercios') <> 1 THEN
    RAISE EXCEPTION 'FALLO 2.2: el otro titular debe ver solo su comercio.';
  END IF;

  -- 2.3 Usuario inexistente o sin confirmar: rechazo.
  v_resp := public.estado_oauth_comercios('00000000-0000-4000-8000-000000000299');
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 2.3a: un usuario inexistente debe rechazarse.';
  END IF;
  v_resp := public.estado_oauth_comercios('00000000-0000-4000-8000-000000000003');
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 2.3b: un usuario sin confirmar correo debe rechazarse.';
  END IF;
END $$;

-- ============================================================================
-- 3. eliminar_oauth_comercio
-- ============================================================================
DO $$
DECLARE
  v_resp jsonb;
BEGIN
  -- 3.1 No titular: rechazo.
  v_resp := public.eliminar_oauth_comercio('00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000002');
  IF (v_resp->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'FALLO 3.1: un no titular no puede desconectar la cuenta.';
  END IF;

  -- 3.2 Titular: desconecta y borra las credenciales.
  v_resp := public.eliminar_oauth_comercio('00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001');
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FALLO 3.2: el titular debe poder desconectar.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.mercado_pago_tokens_privado WHERE comercio_id = '00000000-0000-4000-8000-000000000101') THEN
    RAISE EXCEPTION 'FALLO 3.2b: las credenciales deben borrarse al desconectar.';
  END IF;

  -- 3.3 La desconexión no borra datos de reclamos ni la configuración.
  IF NOT EXISTS (SELECT 1 FROM public.comercio_codigos_reclamo WHERE comercio_id = '00000000-0000-4000-8000-000000000103') THEN
    RAISE EXCEPTION 'FALLO 3.3: los códigos de reclamo no deben borrarse al desconectar.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pedidos WHERE id = '00000000-0000-4000-8000-000000000201') THEN
    RAISE EXCEPTION 'FALLO 3.4: los pedidos no deben borrarse al desconectar.';
  END IF;
  IF (SELECT porcentaje_comision FROM public.configuracion_plataforma WHERE id = 1) <> 5 THEN
    RAISE EXCEPTION 'FALLO 3.5: la configuración de comisión debe conservarse.';
  END IF;
  IF (SELECT estado FROM public.conexiones_mercado_pago WHERE comercio_id = '00000000-0000-4000-8000-000000000101') <> 'desconectado' THEN
    RAISE EXCEPTION 'FALLO 3.6: la conexión debe marcarse como desconectada.';
  END IF;
END $$;

-- ============================================================================
-- 4. Comisión configurable
-- ============================================================================
DO $$
DECLARE
  v_comision numeric;
BEGIN
  v_comision := public.obtener_comision_plataforma();
  IF v_comision <> 0.05 THEN
    RAISE EXCEPTION 'FALLO 4.1: la comisión por defecto debe ser 0.05 (%).', v_comision;
  END IF;

  PERFORM public.establecer_comision_plataforma(0.06);
  IF public.obtener_comision_plataforma() <> 0.06 THEN
    RAISE EXCEPTION 'FALLO 4.2: la comisión cambiada debe leerse de la configuración.';
  END IF;

  BEGIN
    PERFORM public.establecer_comision_plataforma(0.9);
    RAISE EXCEPTION 'FALLO 4.3: una comisión fuera de rango debe rechazarse.';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLO%' THEN RAISE; END IF;
  END;

  PERFORM public.establecer_comision_plataforma(0.05);
END $$;

-- ============================================================================
-- 5. Permisos: la API pública no puede ejecutar estas funciones.
-- ============================================================================
DO $$
DECLARE
  v_resp jsonb;
BEGIN
  SET LOCAL ROLE anon;
  BEGIN
    v_resp := public.consultar_estado_pedido('00000000-0000-4000-8000-000000000201', repeat('a', 64));
    RAISE EXCEPTION 'FALLO 5.1: anon no debe poder ejecutar consultar_estado_pedido.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- comportamiento esperado
  END;

  BEGIN
    v_resp := public.estado_oauth_comercios('00000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'FALLO 5.2: anon no debe poder ejecutar estado_oauth_comercios.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;

-- 6. El service_role SÍ puede ejecutarlas (lo usan las Edge Functions).
DO $$
DECLARE
  v_resp jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  v_resp := public.consultar_estado_pedido('00000000-0000-4000-8000-000000000201', repeat('a', 64));
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FALLO 6.1: service_role debe poder consultar el estado.';
  END IF;
  v_resp := public.estado_oauth_comercios('00000000-0000-4000-8000-000000000001');
  IF (v_resp->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FALLO 6.2: service_role debe poder consultar la conexión.';
  END IF;
END $$;
