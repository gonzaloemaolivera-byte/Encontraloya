-- ============================================================================
-- Encontralo Ya — Migración comercial PARA REVISIÓN
-- ============================================================================
-- BORRADOR: NO EJECUTAR en producción sin autorización expresa.
-- Usa la columna propietario_id que ya existe en public.comercios.
-- No crea auth_user_id, no modifica datos existentes y no cambia RLS.
--
-- Permite que una cuenta de Supabase Auth administre VARIOS comercios.
-- Cada comercio sigue teniendo un solo propietario_id.
-- ============================================================================

BEGIN;

-- Índice no único: un mismo usuario puede tener muchos comercios.
CREATE INDEX IF NOT EXISTS comercios_propietario_id_idx
  ON public.comercios (propietario_id)
  WHERE propietario_id IS NOT NULL;

-- Lista solo los comercios todavía no reclamados. Nunca devuelve el código.
CREATE OR REPLACE FUNCTION public.comercios_sin_reclamar()
RETURNS TABLE (id uuid, nombre text, localidad text, provincia text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT c.id, c.nombre::text, c.localidad::text, c.provincia::text
  FROM public.comercios AS c
  WHERE c.propietario_id IS NULL
    AND c.codigo_vendedor IS NOT NULL
    AND pg_catalog.btrim(c.codigo_vendedor) <> ''
  ORDER BY c.nombre;
$function$;

-- Reclama un comercio mediante su código privado validado en la base.
-- propietario_id permite que una misma cuenta reclame más de un comercio.
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
  v_reclamado boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Iniciá sesión con tu correo y contraseña para reclamar el comercio.'
    );
  END IF;

  IF p_comercio_id IS NULL
     OR p_codigo IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_codigo)) NOT BETWEEN 6 AND 40 THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'mensaje', 'Revisá el código privado. Debe tener entre 6 y 40 caracteres.'
    );
  END IF;

  UPDATE public.comercios AS c
     SET propietario_id = v_uid
   WHERE c.id = p_comercio_id
     AND c.propietario_id IS NULL
     AND c.codigo_vendedor = pg_catalog.btrim(p_codigo)
  RETURNING true INTO v_reclamado;

  IF v_reclamado THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'mensaje', 'Comercio vinculado correctamente a tu cuenta.'
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'ok', false,
    'mensaje', 'No pudimos vincular el comercio: el código no coincide o el comercio ya tiene titular. Escribinos para revisarlo.'
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
  v_moneda text := pg_catalog.upper(pg_catalog.btrim(pg_catalog.coalesce(p_moneda, 'ARS')));
BEGIN
  IF v_uid IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'mensaje', 'Iniciá sesión para publicar productos.');
  END IF;

  IF NOT EXISTS (
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
     pg_catalog.nullif(pg_catalog.btrim(pg_catalog.coalesce(p_descripcion, '')), ''),
     pg_catalog.nullif(pg_catalog.btrim(pg_catalog.coalesce(p_categoria, '')), ''),
     CASE WHEN p_precio IS NULL THEN NULL ELSE pg_catalog.round(p_precio, 2) END,
     v_moneda,
     pg_catalog.coalesce(p_disponible, true))
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
  v_moneda text := pg_catalog.upper(pg_catalog.btrim(pg_catalog.coalesce(p_moneda, 'ARS')));
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
         descripcion = pg_catalog.nullif(pg_catalog.btrim(pg_catalog.coalesce(p_descripcion, '')), ''),
         categoria = pg_catalog.nullif(pg_catalog.btrim(pg_catalog.coalesce(p_categoria, '')), ''),
         precio = CASE WHEN p_precio IS NULL THEN NULL ELSE pg_catalog.round(p_precio, 2) END,
         moneda = v_moneda,
         disponible = pg_catalog.coalesce(p_disponible, true)
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
-- * No modifica ni elimina comercios o productos existentes.
-- * No cambia políticas RLS ni permisos DELETE/SELECT de las tablas.
-- * No crea auth_user_id: usa public.comercios.propietario_id.
-- * Una misma cuenta puede administrar varios comercios.
