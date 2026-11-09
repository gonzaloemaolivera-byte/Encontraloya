-- ============================================================================
-- Encontralo Ya — Migración comercial PARA REVISIÓN
-- ============================================================================
-- Estado: BORRADOR PARA REVISIÓN. NO EJECUTAR en producción sin la
-- aprobación de Gonzalo. Ver docs/documentacion-panel-comercio.md para el
-- procedimiento de aplicación segura.
--
-- Objetivos:
--   1. Permitir que cada comercio tenga un acceso privado (Supabase Auth,
--      correo y contraseña) sin tocar comercios, productos ni datos
--      existentes: todos los cambios son ADITIVOS.
--   2. Que el reclamo de un comercio valide el código privado (columna
--      codigo_vendedor) EN EL SERVIDOR, mediante funciones SECURITY DEFINER.
--      El código nunca viaja al navegador ni queda expuesto en consultas
--      públicas.
--   3. Que cada comercio solo pueda administrar SUS PROPIOS productos y que
--      NO exista ninguna vía para borrar datos (ni por el panel ni por la
--      API pública).
--   4. Mantener el catálogo y las búsquedas públicas exactamente como
--      funcionan hoy.
--
-- La migración se ejecuta completa dentro de una transacción: si algo falla,
-- se revierte sola (BEGIN/COMMIT).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Vínculo comercio <-> usuario de Supabase Auth
-- ----------------------------------------------------------------------------
-- Columna nueva, nullable. Los comercios existentes quedan igual (sin dueño
-- asignado) hasta que su titular los reclame con su código privado.
ALTER TABLE public.comercios
  ADD COLUMN IF NOT EXISTS auth_user_id uuid REFERENCES auth.users (id)
  ON DELETE SET NULL;

-- Un usuario de auth puede ser titular de un solo comercio.
CREATE UNIQUE INDEX IF NOT EXISTS comercios_un_usuario_por_comercio
  ON public.comercios (auth_user_id)
  WHERE auth_user_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2) Protección de la columna codigo_vendedor
-- ----------------------------------------------------------------------------
-- Hoy el acceso público de lectura usa permisos por columna y codigo_vendedor
-- NO está incluido. Esta línea lo deja explícito y a prueba de futuros
-- "GRANT SELECT ON ALL TABLES" accidentales. No modifica ningún dato.
REVOKE SELECT (codigo_vendedor) ON public.comercios FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3) Cierre defensivo: sin borrados por la API pública
-- ----------------------------------------------------------------------------
-- Durante la revisión se verificó que el rol anon puede ejecutar DELETE sobre
-- productos (PostgREST devuelve 204). Ninguna funcionalidad pública o del
-- panel necesita borrar, así que se revoca el permiso. Esto no elimina datos:
-- solo cierra la posibilidad de borrarlos por error.
REVOKE DELETE ON public.productos FROM anon, authenticated;
REVOKE DELETE ON public.comercios FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4) Funciones SECURITY DEFINER para el panel del comercio
-- ----------------------------------------------------------------------------
-- Se usan funciones en lugar de permisos directos sobre las tablas para que:
--   * la validación del codigo_vendedor ocurra dentro de la base (servidor),
--   * cada comercio solo alcance SUS propios productos,
--   * no exista ninguna operación de borrado.

-- Lista de comercios sin titular, para que su dueño los reclame desde el
-- panel. No expone codigo_vendedor ni teléfonos.
CREATE OR REPLACE FUNCTION public.comercios_sin_reclamar()
RETURNS TABLE (id uuid, nombre text, localidad text, provincia text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.id, c.nombre, c.localidad, c.provincia
  FROM public.comercios c
  WHERE c.auth_user_id IS NULL
  ORDER BY c.nombre ASC;
$$;

-- Reclama un comercio: valida el código privado en el servidor y vincula el
-- comercio al usuario autenticado. Un solo UPDATE atómico evita que se
-- reclame dos veces. Un código incorrecto y un comercio ya reclamado dan el
-- mismo mensaje genérico, sin filtrar información.
CREATE OR REPLACE FUNCTION public.reclamar_comercio(
  p_comercio_id uuid,
  p_codigo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_reclamado boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'mensaje', 'Iniciá sesión con tu correo y contraseña para reclamar el comercio.');
  END IF;

  IF p_codigo IS NULL OR length(btrim(p_codigo)) NOT BETWEEN 6 AND 40 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'mensaje', 'Revisá el código privado. Debe tener entre 6 y 40 caracteres.');
  END IF;

  UPDATE public.comercios
     SET auth_user_id = v_uid
   WHERE id = p_comercio_id
     AND auth_user_id IS NULL
     AND codigo_vendedor = btrim(p_codigo)
  RETURNING true INTO v_reclamado;

  IF v_reclamado THEN
    RETURN jsonb_build_object('ok', true, 'mensaje', 'Comercio reclamado correctamente.');
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'mensaje', 'No pudimos reclamar el comercio: el código no coincide o el comercio ya tiene titular. Escribinos para revisarlo.');
END;
$$;

-- Devuelve los datos del comercio del usuario autenticado, sin
-- codigo_vendedor.
CREATE OR REPLACE FUNCTION public.datos_del_comercio()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT to_jsonb(c) - 'codigo_vendedor' - 'auth_user_id'
  FROM public.comercios c
  WHERE c.auth_user_id = auth.uid();
$$;

-- Alta de productos: solo para el comercio del usuario autenticado.
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
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Iniciá sesión para publicar productos.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.comercios
     WHERE id = p_comercio_id AND auth_user_id = v_uid
  ) THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Solo podés publicar productos de tu propio comercio.');
  END IF;

  IF p_nombre IS NULL OR length(btrim(p_nombre)) NOT BETWEEN 2 AND 120 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'El nombre del producto debe tener entre 2 y 120 caracteres.');
  END IF;

  IF p_precio IS NOT NULL AND p_precio < 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'El precio no puede ser negativo.');
  END IF;

  INSERT INTO public.productos
    (comercio_id, nombre, descripcion, categoria, precio, moneda, disponible)
  VALUES
    (p_comercio_id,
     btrim(p_nombre),
     nullif(btrim(p_descripcion), ''),
     nullif(btrim(p_categoria), ''),
     p_precio,
     coalesce(nullif(btrim(p_moneda), ''), 'ARS'),
     coalesce(p_disponible, true))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id,
    'mensaje', 'Producto publicado en el catálogo.');
END;
$$;

-- Edición de productos: solo los del propio comercio. No existe función de
-- borrado a propósito: los productos solo se marcan como no disponibles.
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
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Iniciá sesión para editar productos.');
  END IF;

  UPDATE public.productos
     SET nombre = btrim(p_nombre),
         descripcion = nullif(btrim(p_descripcion), ''),
         categoria = nullif(btrim(p_categoria), ''),
         precio = p_precio,
         moneda = coalesce(nullif(btrim(p_moneda), ''), 'ARS'),
         disponible = coalesce(p_disponible, true)
   WHERE id = p_producto_id
     AND comercio_id IN (
       SELECT id FROM public.comercios WHERE auth_user_id = v_uid
     )
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Solo podés editar productos de tu propio comercio.');
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id,
    'mensaje', 'Producto actualizado.');
END;
$$;

-- Las funciones se ejecutan solo con sesión iniciada (rol authenticated).
REVOKE EXECUTE ON FUNCTION public.comercios_sin_reclamar()  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reclamar_comercio(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.datos_del_comercio() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crear_producto(uuid, text, text, text, numeric, text, boolean) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.actualizar_producto(uuid, text, text, text, numeric, text, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.comercios_sin_reclamar()  TO authenticated;
GRANT EXECUTE ON FUNCTION public.reclamar_comercio(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.datos_del_comercio() TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_producto(uuid, text, text, text, numeric, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_producto(uuid, text, text, text, numeric, text, boolean) TO authenticated;

COMMIT;

-- ============================================================================
-- Qué NO hace esta migración (para la revisión):
--   * No ejecuta UPDATE ni DELETE sobre filas existentes: solo agrega una
--     columna, un índice y funciones nuevas.
--   * No habilita RLS ni cambia los permisos existentes de lectura y de
--     registro del catálogo y del formulario público.
--   * No toca el contenido de la columna codigo_vendedor ni lo expone.
-- ============================================================================
