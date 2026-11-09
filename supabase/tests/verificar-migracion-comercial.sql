\set ON_ERROR_STOP on

-- La migración debe preservar los registros existentes.
DO $$
BEGIN
  IF (SELECT count(*) FROM public.comercios) <> 7 THEN
    RAISE EXCEPTION 'Se alteró la cantidad inicial de comercios';
  END IF;
  IF (SELECT count(*) FROM public.productos) <> 4 THEN
    RAISE EXCEPTION 'Se alteró la cantidad inicial de productos';
  END IF;
  IF EXISTS (SELECT 1 FROM public.comercios WHERE codigo_vendedor IS NOT NULL) THEN
    RAISE EXCEPTION 'Quedó un código antiguo en la columna pública';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.comercios'::regclass
      AND NOT tgisinternal
      AND tgname IN ('asignar_codigo_vendedor', 'generar_codigo_vinculacion')
  ) THEN
    RAISE EXCEPTION 'Sigue activo un disparador de códigos heredado';
  END IF;
  IF has_function_privilege('anon', 'public.vincular_comercio(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.vincular_comercio(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'La RPC heredada sigue ejecutable';
  END IF;
  IF has_table_privilege('anon', 'private.comercio_codigos_reclamo', 'SELECT')
     OR has_table_privilege('authenticated', 'private.comercio_codigos_reclamo', 'SELECT')
     OR has_table_privilege('anon', 'private.comercio_reclamo_intentos', 'SELECT')
     OR has_table_privilege('authenticated', 'private.comercio_reclamo_intentos', 'SELECT') THEN
    RAISE EXCEPTION 'Un rol de cliente puede leer tablas privadas';
  END IF;
  IF has_table_privilege('anon', 'public.encontralo_revision_telefonos_v1', 'SELECT')
     OR has_table_privilege('authenticated', 'public.encontralo_revision_telefonos_v1', 'SELECT') THEN
    RAISE EXCEPTION 'La vista interna de teléfonos sigue accesible por API';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'encontralo_revision_telefonos_v1'
      AND c.reloptions @> ARRAY['security_invoker=true']
  ) THEN
    RAISE EXCEPTION 'La vista interna no quedó como security_invoker';
  END IF;
  IF has_function_privilege('anon', 'public.reclamar_comercio(uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.reclamar_comercio(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Los permisos de reclamar_comercio no son correctos';
  END IF;
END;
$$;

-- Las dos cuentas de prueba reciben códigos aleatorios de 256 bits.
INSERT INTO private.comercio_codigos_reclamo (comercio_id, codigo_hash)
SELECT id, pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.repeat('a', 64), 'UTF8'))
FROM public.comercios WHERE nombre = 'Comercio 1';

INSERT INTO private.comercio_codigos_reclamo (comercio_id, codigo_hash)
SELECT id, pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.repeat('b', 64), 'UTF8'))
FROM public.comercios WHERE nombre = 'Comercio 2';

-- Una cuenta sin correo confirmado no puede enumerar comercios reclamables.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', false);
SET ROLE authenticated;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.comercios_sin_reclamar()) <> 0 THEN
    RAISE EXCEPTION 'Una cuenta sin confirmar pudo listar comercios';
  END IF;
END;
$$;
RESET ROLE;

-- La cuenta confirmada ve solo los comercios pendientes con hash provisionado.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', false);
SET ROLE authenticated;
DO $$
DECLARE
  v_comercio uuid;
  v_resultado jsonb;
  v_producto uuid;
  v_i integer;
BEGIN
  IF (SELECT count(*) FROM public.comercios_sin_reclamar()) <> 2 THEN
    RAISE EXCEPTION 'La lista de comercios pendientes no coincide';
  END IF;

  SELECT id INTO v_comercio FROM public.comercios WHERE nombre = 'Comercio 1';

  v_resultado := public.reclamar_comercio(v_comercio, pg_catalog.repeat('a', 64));
  IF v_resultado->>'ok' <> 'true' THEN
    RAISE EXCEPTION 'No se pudo reclamar con un código válido: %', v_resultado;
  END IF;

  v_resultado := public.reclamar_comercio(v_comercio, pg_catalog.repeat('a', 64));
  IF v_resultado->>'ok' <> 'false' THEN
    RAISE EXCEPTION 'El código pudo reutilizarse';
  END IF;

  IF (SELECT count(*) FROM public.datos_del_comercio()) <> 1 THEN
    RAISE EXCEPTION 'La cuenta no ve su comercio vinculado';
  END IF;

  v_resultado := public.crear_producto(
    v_comercio, 'Producto del titular', 'Descripción', 'Ferretería', 123.45, 'ARS', true
  );
  IF v_resultado->>'ok' <> 'true' THEN
    RAISE EXCEPTION 'El titular no pudo crear su producto: %', v_resultado;
  END IF;
  v_producto := (v_resultado->>'id')::uuid;

  v_resultado := public.actualizar_producto(
    v_producto, 'Producto editado', 'Descripción editada', 'Ferretería', 150, 'ARS', true
  );
  IF v_resultado->>'ok' <> 'true' THEN
    RAISE EXCEPTION 'El titular no pudo editar su producto: %', v_resultado;
  END IF;

  SELECT id INTO v_comercio FROM public.comercios WHERE nombre = 'Comercio 2';
  FOR v_i IN 1..5 LOOP
    v_resultado := public.reclamar_comercio(v_comercio, pg_catalog.repeat('c', 64));
  END LOOP;
  IF v_resultado->>'mensaje' NOT LIKE 'Se alcanzó el límite de intentos%' THEN
    RAISE EXCEPTION 'No se activó el bloqueo al quinto intento: %', v_resultado;
  END IF;
  v_resultado := public.reclamar_comercio(v_comercio, pg_catalog.repeat('b', 64));
  IF v_resultado->>'mensaje' NOT LIKE 'Se alcanzó el límite de intentos%' THEN
    RAISE EXCEPTION 'El bloqueo no impidió un intento posterior';
  END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM private.comercio_codigos_reclamo k
    JOIN public.comercios c ON c.id = k.comercio_id
    WHERE c.nombre = 'Comercio 1'
  ) THEN
    RAISE EXCEPTION 'El hash no se consumió después del reclamo';
  END IF;
END;
$$;

-- Otra cuenta no puede editar productos ni reclamar un comercio ya asignado.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', false);
SET ROLE authenticated;
DO $$
DECLARE
  v_comercio uuid;
  v_producto uuid;
  v_resultado jsonb;
BEGIN
  SELECT id INTO v_comercio FROM public.comercios WHERE nombre = 'Comercio 1';
  SELECT id INTO v_producto FROM public.productos WHERE nombre = 'Producto editado';

  v_resultado := public.reclamar_comercio(v_comercio, pg_catalog.repeat('a', 64));
  IF v_resultado->>'ok' <> 'false' THEN
    RAISE EXCEPTION 'Una segunda cuenta reclamó un comercio asignado';
  END IF;

  v_resultado := public.actualizar_producto(
    v_producto, 'Intento ajeno', '', 'Otros', 1, 'ARS', true
  );
  IF v_resultado->>'ok' <> 'false' THEN
    RAISE EXCEPTION 'Una segunda cuenta pudo editar un producto ajeno';
  END IF;
END;
$$;
RESET ROLE;

-- El catálogo público sigue leyendo productos existentes.
SET ROLE anon;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.productos) <> 5 THEN
    RAISE EXCEPTION 'La lectura pública del catálogo dejó de funcionar';
  END IF;
END;
$$;

-- El alta pública sigue funcionando y ya no dispara la generación de códigos viejos.
DO $$
DECLARE
  v_codigo text;
BEGIN
  INSERT INTO public.comercios (nombre, rubro, localidad, provincia, telefono)
  VALUES ('Nuevo registro de prueba', 'Otros', 'Moreno', 'Buenos Aires', '1122223333')
  RETURNING codigo_vendedor INTO v_codigo;

  IF v_codigo IS NOT NULL THEN
    RAISE EXCEPTION 'El alta pública volvió a generar codigo_vendedor';
  END IF;
END;
$$;
RESET ROLE;

-- El test termina con 8 comercios y 5 productos; ningún dato real está involucrado.
DO $$
BEGIN
  IF (SELECT count(*) FROM public.comercios) <> 8 THEN
    RAISE EXCEPTION 'Cantidad final de comercios inesperada';
  END IF;
  IF (SELECT count(*) FROM public.productos) <> 5 THEN
    RAISE EXCEPTION 'Cantidad final de productos inesperada';
  END IF;
  RAISE NOTICE 'OK: migración comercial, permisos, reclamo, bloqueo, catálogo y alta pública';
END;
$$;
