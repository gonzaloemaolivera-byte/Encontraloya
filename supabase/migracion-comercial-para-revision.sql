-- =====================================================================
-- Encontralo Ya · Migración comercial PARA REVISIÓN
-- Archivo: supabase/migracion-comercial-para-revision.sql
--
-- Propósito: habilitar el Panel de comercio (panel-comercio.html) para
-- que cada comercio gestione la publicación de sus propios productos,
-- sin que pueda tocar los datos de otros comercios.
--
-- GARANTÍAS DE ESTA MIGRACIÓN:
--   * Es 100% aditiva: solo crea tablas, columnas, índices y políticas
--     si todavía no existen. No contiene ningún UPDATE, DELETE ni
--     TRUNCATE: no modifica ni elimina ningún dato existente.
--   * No deshabilita ni reemplaza políticas ni permisos existentes.
--   * El sitio actual (index.html) sigue leyendo comercios y productos
--     exactamente igual que hoy.
--
-- Ejecutar en el SQL Editor de Supabase tras la revisión de Gonzalo.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) Tablas base (solo se crean si aún no existen; con las mismas
--    columnas que ya usa el sitio actual).
-- ---------------------------------------------------------------------

create table if not exists public.comercios (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  nombre text not null,
  rubro text,
  localidad text not null,
  provincia text not null,
  telefono text not null,
  contacto text,
  direccion text,
  que_vende text
);

create table if not exists public.productos (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  comercio_id uuid not null references public.comercios (id) on delete cascade,
  nombre text not null,
  descripcion text,
  categoria text,
  precio numeric(12, 2),
  moneda text not null default 'ARS',
  disponible boolean not null default true
);

-- ---------------------------------------------------------------------
-- 2) Columnas nuevas del panel (solo se agregan si no existen; los
--    valores de las filas existentes quedan intactos: NULL).
-- ---------------------------------------------------------------------

-- Código de acceso privado del comercio para usar el panel.
alter table public.comercios
  add column if not exists panel_codigo text;

-- Fecha del último cambio hecho desde el panel sobre cada producto.
alter table public.productos
  add column if not exists actualizado_en timestamptz;

-- ---------------------------------------------------------------------
-- 3) Índices necesarios para el panel (no alteran datos).
-- ---------------------------------------------------------------------

create index if not exists productos_comercio_idx
  on public.productos (comercio_id);

create index if not exists productos_disponible_idx
  on public.productos (disponible);

-- Un código de panel no puede repetirse entre comercios.
-- Los comercios sin código (NULL) conviven sin problema.
create unique index if not exists comercios_panel_codigo_key
  on public.comercios (panel_codigo);

-- ---------------------------------------------------------------------
-- 4) Seguridad del panel (RLS), 100% aditiva.
--
-- Cómo funciona:
--   * Cada comercio se identifica en el panel con su teléfono
--     registrado (dato ya público en el catálogo).
--   * Toda escritura (alta de producto, pausa/reactivación, asignación
--     de código) envía el encabezado HTTP "x-panel-codigo".
--   * Las políticas comparan ese encabezado contra comercios.panel_codigo
--     mediante current_setting('request.headers', true).
--
-- Notas importantes:
--   * Las políticas solo AGREGAN permisos; no cambian nada de lo que ya
--     funciona hoy. Si el proyecto aún no tiene RLS activado en estas
--     tablas, esta migración no lo activa: habilitarlo exige revisar las
--     políticas de lectura del catálogo público y queda para una
--     decisión posterior de Gonzalo.
--   * El alta de producto solo se permite para el comercio dueño del
--     código enviado. No se permite borrar productos desde el panel
--     (solo pausar/reactivar), así la migración garantiza que no se
--     puedan eliminar datos.
-- ---------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'comercios'
      and policyname = 'comercios_panel_reclamar_codigo'
  ) then
    create policy comercios_panel_reclamar_codigo
      on public.comercios
      for update of panel_codigo
      to anon, authenticated
      using (panel_codigo is null)
      with check (
        panel_codigo is not null
        and panel_codigo = current_setting('request.headers', true)::json ->> 'x-panel-codigo'
      );
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'productos'
      and policyname = 'productos_panel_alta'
  ) then
    create policy productos_panel_alta
      on public.productos
      for insert
      to anon, authenticated
      with check (
        exists (
          select 1 from public.comercios c
          where c.id = comercio_id
            and c.panel_codigo is not null
            and c.panel_codigo = current_setting('request.headers', true)::json ->> 'x-panel-codigo'
        )
      );
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'productos'
      and policyname = 'productos_panel_actualizar'
  ) then
    create policy productos_panel_actualizar
      on public.productos
      for update
      to anon, authenticated
      using (
        exists (
          select 1 from public.comercios c
          where c.id = comercio_id
            and c.panel_codigo is not null
            and c.panel_codigo = current_setting('request.headers', true)::json ->> 'x-panel-codigo'
        )
      )
      with check (
        exists (
          select 1 from public.comercios c
          where c.id = comercio_id
            and c.panel_codigo is not null
            and c.panel_codigo = current_setting('request.headers', true)::json ->> 'x-panel-codigo'
        )
      );
  end if;
end
$$;

commit;

-- ---------------------------------------------------------------------
-- 5) (OPCIONAL, NO SE EJECUTA CON ESTA MIGRACIÓN)
--
-- Generar códigos de panel para comercios ya registrados. Este bloque
-- SÍ modificaría datos existentes, por lo que queda comentado: solo
-- debe ejecutarlo Gonzalo con autorización explícita, tras revisar el
-- listado de comercios.
--
-- update public.comercios
--   set panel_codigo = substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)
--   where panel_codigo is null;
-- ---------------------------------------------------------------------
