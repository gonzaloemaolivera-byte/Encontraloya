-- ============================================================================
-- Encontralo Ya — Migración comercial PARA REVISIÓN
-- ============================================================================
-- BORRADOR: NO EJECUTAR en producción sin autorización expresa.
-- Usa la columna propietario_id que ya existe en public.comercios.
-- No crea auth_user_id ni altera datos comerciales/productos. Desactiva los
-- disparadores y la RPC antiguos para evitar códigos débiles o texto plano.
--
-- Permite que una cuenta de Supabase Auth administre VARIOS comercios.
-- Cada comercio sigue teniendo un solo propietario_id.
-- Los códigos se guardan como SHA-256 en una tabla privada, nunca en texto
-- plano en public.comercios. Solo se aceptan tokens hexadecimales de 64
-- caracteres (256 bits). Todos los códigos preexistentes se invalidan.
-- La migración no genera ni entrega tokens: deben provisionarse por un canal
-- administrativo seguro y entregarse directamente al titular.
-- ============================================================================

BEGIN;

-- El esquema privado ya existe en el proyecto. Se declara por seguridad
-- para que el script también sea autocontenido en una copia local.
CREATE SCHEMA IF NOT EXISTS private;

-- Los disparadores heredados son incompatibles con el CHECK que mantiene
-- codigo_vendedor en NULL. El segundo también seguiría creando códigos
-- antiguos de 12 caracteres que ya no deben aceptarse.
DROP TRIGGER IF EXISTS asignar_codigo_vendedor ON public.comercios;
DROP TRIGGER IF EXISTS generar_codigo_vinculacion ON public.comercios;

-- Deshabilita el endpoint de vinculación legado de 12 caracteres.
REVOKE EXECUTE ON FUNCTION public.vincular_comercio(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.generar_codigo_vendedor() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.generar_codigo_vinculacion() FROM PUBLIC, anon, authenticated;

-- Índice no único: un mismo usuario puede tener muchos comercios.
CREATE INDEX IF NOT EXISTS comercios_propietario_id_idx
  ON public.comercios (propietario_id)
  WHERE propietario_id IS NOT NULL;

-- Almacén privado de hashes de códigos de un solo uso.
-- SHA-256 es adecuado porque cada token tiene 256 bits de entropía.
CREATE TABLE IF NOT EXISTS private.comercio_codigos_reclamo (
  comercio_id uuid PRIMARY KEY
    REFERENCES public.comercios(id) ON DELETE CASCADE,
  codigo_hash bytea NOT NULL
    CHECK (pg_catalog.octet_length(codigo_hash) = 32),
  creado_en timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE private.comercio_codigos_reclamo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.comercio_codigos_reclamo FROM PUBLIC, anon, authenticated;

-- Intentos separados por cuenta y comercio: 5 intentos cada 15 minutos,
-- con bloqueo temporal de 30 minutos. La tabla no es accesible por API.
CREATE TABLE IF NOT EXISTS private.comercio_reclamo_intentos (
  comercio_id uuid NOT NULL
    REFERENCES public.comercios(id) ON DELETE CASCADE,
  usuario_id uuid NOT NULL,
  intentos smallint NOT NULL DEFAULT 0
    CHECK (intentos BETWEEN 0 AND 5),
  ventana_inicio timestamptz NOT NULL DEFAULT pg_catalog.now(),
  bloqueado_hasta timestamptz,
  PRIMARY KEY (comercio_id, usuario_id)
);

ALTER TABLE private.comercio_reclamo_intentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.comercio_reclamo_intentos FROM PUBLIC, anon, authenticated;

-- No se conserva ningún código preexistente: su entropía no puede demostrarse
-- solo por su longitud. Todos deberán emitirse nuevamente como tokens aleatorios.
CREATE UNIQUE INDEX IF NOT EXISTS comercio_codigos_reclamo_hash_uidx
  ON private.comercio_codigos_reclamo (codigo_hash);

-- Elimina todos los tokens en texto plano de la tabla pública y evita que
-- futuras altas vuelvan a guardar códigos en esa columna obsoleta.
ALTER TABLE public.comercios
  ALTER COLUMN codigo_vendedor DROP DEFAULT;
ALTER TABLE public.comercios
  ALTER COLUMN codigo_vendedor DROP NOT NULL;

UPDATE public.comercios
SET codigo_vendedor = NULL
WHERE codigo_vendedor IS NOT NULL;

ALTER TABLE public.comercios
  DROP CONSTRAINT IF EXISTS comercios_codigo_vendedor_siempre_nulo_check;

ALTER TABLE public.comercios
  ADD CONSTRAINT comercios_codigo_vendedor_siempre_nulo_check
  CHECK (codigo_vendedor IS NULL);

-- Lista solo los comercios todavía no reclamados y con código provisionado.
-- Devuelve nombre/localidad/provincia, nunca el código privado.
CREATE OR REPLACE FUNCTION public.comercios_sin_reclamar()
RETURNS TABLE (id uuid, nombre text, localidad text, provincia text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT c.id, c.nombre::text, c.localidad::text, c.provincia::text
  FROM public.comercios AS c
  INNER JOIN private.comercio_codigos_reclamo AS k
    ON k.comercio_id = c.id
  WHERE c.propietario_id IS NULL
  ORDER BY c.nombre;
$function$;

-- Reclama un comercio con token de un solo uso. Nunca almacena ni devuelve
-- el token en texto plano. Limita intentos por usuario y comercio.
CREATE OR REPLACE FUNCTION public.reclamar_comercio(
  p_comercio_id uuid,
  p_codigo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_email_confirmado timestamptz;
  v_hash bytea;
  v_intentos smallint;
  v_bloqueado_hasta timestamptz;
  v_reclamado boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Iniciá sesión con tu correo y contraseña para reclamar el comercio.'
    );
  END IF;

  SELECT u.email_confirmed_at
    INTO v_email_confirmado
  FROM auth.users AS u
  WHERE u.id = v_uid;

  IF v_email_confirmado IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Primero confirmá tu correo electrónico para reclamar un comercio.'
    );
  END IF;

  IF p_comercio_id IS NULL
     OR p_codigo IS NULL
     OR p_codigo !~ '^[0-9A-Fa-f]{64}$' THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'El código privado no es válido. Revisá los 64 caracteres e intentá nuevamente.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.comercios AS c
    WHERE c.id = p_comercio_id
      AND c.propietario_id IS NULL
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'No pudimos vincular el comercio: el código no coincide o el comercio ya tiene titular. Escribinos para revisarlo.'
    );
  END IF;

  SELECT a.intentos, a.bloqueado_hasta
    INTO v_intentos, v_bloqueado_hasta
  FROM private.comercio_reclamo_intentos AS a
  WHERE a.comercio_id = p_comercio_id
    AND a.usuario_id = v_uid
  FOR UPDATE;

  IF v_bloqueado_hasta IS NOT NULL
     AND v_bloqueado_hasta > pg_catalog.now() THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Se alcanzó el límite de intentos. Esperá 30 minutos antes de volver a probar.'
    );
  END IF;

  SELECT k.codigo_hash
    INTO v_hash
  FROM private.comercio_codigos_reclamo AS k
  WHERE k.comercio_id = p_comercio_id;

  IF v_hash IS NOT NULL
     AND v_hash = pg_catalog.sha256(
       pg_catalog.convert_to(pg_catalog.lower(pg_catalog.btrim(p_codigo)), 'UTF8')
     ) THEN
    UPDATE public.comercios AS c
       SET propietario_id = v_uid
     WHERE c.id = p_comercio_id
       AND c.propietario_id IS NULL
    RETURNING true INTO v_reclamado;

    IF v_reclamado THEN
      DELETE FROM private.comercio_codigos_reclamo
      WHERE comercio_id = p_comercio_id;

      DELETE FROM private.comercio_reclamo_intentos
      WHERE comercio_id = p_comercio_id
        AND usuario_id = v_uid;

      RETURN pg_catalog.jsonb_build_object(
        'ok', true,
        'mensaje', 'Comercio vinculado correctamente a tu cuenta.'
      );
    END IF;
  END IF;

  INSERT INTO private.comercio_reclamo_intentos
    (comercio_id, usuario_id, intentos, ventana_inicio, bloqueado_hasta)
  VALUES
    (p_comercio_id, v_uid, 1, pg_catalog.now(), NULL)
  ON CONFLICT (comercio_id, usuario_id) DO UPDATE
  SET intentos = CASE
        WHEN private.comercio_reclamo_intentos.ventana_inicio
             < pg_catalog.now() - interval '15 minutes' THEN 1
        WHEN private.comercio_reclamo_intentos.intentos >= 5 THEN 5
        ELSE private.comercio_reclamo_intentos.intentos + 1
      END,
      ventana_inicio = CASE
        WHEN private.comercio_reclamo_intentos.ventana_inicio
             < pg_catalog.now() - interval '15 minutes' THEN pg_catalog.now()
        ELSE private.comercio_reclamo_intentos.ventana_inicio
      END,
      bloqueado_hasta = CASE
        WHEN CASE
          WHEN private.comercio_reclamo_intentos.ventana_inicio
               < pg_catalog.now() - interval '15 minutes' THEN 1
          ELSE private.comercio_reclamo_intentos.intentos + 1
        END >= 5
        THEN pg_catalog.now() + interval '30 minutes'
        ELSE NULL
      END
  RETURNING intentos, bloqueado_hasta
    INTO v_intentos, v_bloqueado_hasta;

  RETURN pg_catalog.jsonb_build_object(
    'ok', false,
    'mensaje', CASE
      WHEN v_bloqueado_hasta IS NOT NULL
        THEN 'Se alcanzó el límite de intentos. Esperá 30 minutos antes de volver a probar.'
      ELSE 'No pudimos vincular el comercio: el código no coincide o el comercio ya tiene titular. Escribinos para revisarlo.'
    END
  );
END;
$function$;

-- Devuelve TODOS los comercios del usuario autenticado (no solo uno).
-- PostgREST entrega una lista de filas para que el panel permita elegir.
CREATE OR REPLACE FUNCTION public.datos_del_comercio()
RETURNS TABLE (
  id uuid,
  nombre text,
  localidad text,
  provincia text,
  rubro text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    c.id,
    c.nombre::text,
    c.localidad::text,
    c.provincia::text,
    c.rubro::text
  FROM public.comercios AS c
  WHERE c.propietario_id = auth.uid()
  ORDER BY c.nombre;
$function$;

-- Alta de productos: solo para un comercio perteneciente al usuario.
CREATE OR REPLACE FUNCTION public.crear_producto(
  p_comercio_id uuid,
  p_nombre text,
  p_descripcion text,
  p_categoria text,
  p_precio numeric,
  p_moneda text,
  p_disponible boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
  v_moneda text := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_moneda, 'ARS')));
BEGIN
  IF v_uid IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Iniciá sesión para publicar productos.');
  END IF;

  IF p_comercio_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.comercios AS c
    WHERE c.id = p_comercio_id
      AND c.propietario_id = v_uid
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Solo podés publicar productos de tus propios comercios.');
  END IF;

  IF p_nombre IS NULL OR pg_catalog.length(pg_catalog.btrim(p_nombre)) NOT BETWEEN 2 AND 120 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'El nombre del producto debe tener entre 2 y 120 caracteres.');
  END IF;

  IF p_descripcion IS NOT NULL AND pg_catalog.length(p_descripcion) > 500 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'La descripción no puede superar los 500 caracteres.');
  END IF;

  IF p_categoria IS NOT NULL AND pg_catalog.length(p_categoria) > 80 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'La categoría no puede superar los 80 caracteres.');
  END IF;

  IF p_precio IS NOT NULL AND (p_precio < 0 OR p_precio > 999999999999.99) THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Revisá el precio ingresado.');
  END IF;

  IF v_moneda NOT IN ('ARS', 'USD') THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'La moneda debe ser ARS o USD.');
  END IF;

  INSERT INTO public.productos
    (comercio_id, nombre, descripcion, categoria, precio, moneda, disponible)
  VALUES
    (p_comercio_id,
     pg_catalog.btrim(p_nombre),
     NULLIF(pg_catalog.btrim(COALESCE(p_descripcion, '')), ''),
     NULLIF(pg_catalog.btrim(COALESCE(p_categoria, '')), ''),
     CASE WHEN p_precio IS NULL THEN NULL ELSE pg_catalog.round(p_precio, 2) END,
     v_moneda,
     COALESCE(p_disponible, true))
  RETURNING id INTO v_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true, 'id', v_id, 'mensaje', 'Producto publicado en el catálogo.'
  );
END;
$function$;

-- Edición: exige que el producto pertenezca a alguno de los comercios del usuario.
CREATE OR REPLACE FUNCTION public.actualizar_producto(
  p_producto_id uuid,
  p_nombre text,
  p_descripcion text,
  p_categoria text,
  p_precio numeric,
  p_moneda text,
  p_disponible boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
  v_moneda text := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_moneda, 'ARS')));
BEGIN
  IF v_uid IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Iniciá sesión para editar productos.');
  END IF;

  IF p_nombre IS NULL OR pg_catalog.length(pg_catalog.btrim(p_nombre)) NOT BETWEEN 2 AND 120 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'El nombre del producto debe tener entre 2 y 120 caracteres.');
  END IF;

  IF p_descripcion IS NOT NULL AND pg_catalog.length(p_descripcion) > 500 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'La descripción no puede superar los 500 caracteres.');
  END IF;

  IF p_categoria IS NOT NULL AND pg_catalog.length(p_categoria) > 80 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'La categoría no puede superar los 80 caracteres.');
  END IF;

  IF p_precio IS NOT NULL AND (p_precio < 0 OR p_precio > 999999999999.99) THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Revisá el precio ingresado.');
  END IF;

  IF v_moneda NOT IN ('ARS', 'USD') THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'La moneda debe ser ARS o USD.');
  END IF;

  UPDATE public.productos AS p
     SET nombre = pg_catalog.btrim(p_nombre),
         descripcion = NULLIF(pg_catalog.btrim(COALESCE(p_descripcion, '')), ''),
         categoria = NULLIF(pg_catalog.btrim(COALESCE(p_categoria, '')), ''),
         precio = CASE WHEN p_precio IS NULL THEN NULL ELSE pg_catalog.round(p_precio, 2) END,
         moneda = v_moneda,
         disponible = COALESCE(p_disponible, true)
   WHERE p.id = p_producto_id
     AND EXISTS (
       SELECT 1
       FROM public.comercios AS c
       WHERE c.id = p.comercio_id
         AND c.propietario_id = v_uid
     )
  RETURNING p.id INTO v_id;

  IF v_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false, 'mensaje', 'No encontramos ese producto entre los comercios de tu cuenta.'
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'id', v_id, 'mensaje', 'Producto actualizado.');
END;
$function$;

-- Solo usuarios autenticados pueden invocar las funciones del panel.
REVOKE EXECUTE ON FUNCTION public.comercios_sin_reclamar() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reclamar_comercio(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.datos_del_comercio() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crear_producto(uuid, text, text, text, numeric, text, boolean) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.actualizar_producto(uuid, text, text, text, numeric, text, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.comercios_sin_reclamar() TO authenticated;
GRANT EXECUTE ON FUNCTION public.reclamar_comercio(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.datos_del_comercio() TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_producto(uuid, text, text, text, numeric, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_producto(uuid, text, text, text, numeric, text, boolean) TO authenticated;

COMMIT;

-- IMPORTANTE:
-- * No se ejecuta esta migración al guardarla en GitHub.
-- * No modifica datos comerciales ni productos; limpia codigo_vendedor,
--   desactiva los disparadores/códigos antiguos y obliga a mantenerlo NULL.
-- * No cambia políticas RLS ni permisos DELETE/SELECT de las tablas
--   principales; activa RLS y revoca acceso en las dos tablas privadas nuevas.
-- * No crea auth_user_id: usa public.comercios.propietario_id.
-- * Una misma cuenta puede administrar varios comercios.
-- * Los códigos se guardan como SHA-256 en una tabla sin acceso por API.
-- * Solo se aceptan tokens aleatorios de 64 caracteres hexadecimales.
-- * Los tokens son de un solo uso y los intentos se limitan por cuenta.
-- * El endpoint legado vincular_comercio(text) queda sin EXECUTE; los códigos
--   viejos de 12 caracteres dejan de servir. Los nuevos se provisionan aparte.
