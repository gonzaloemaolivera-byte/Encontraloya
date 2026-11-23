-- Administración de comercios en Encontralo Ya.
-- Los registros existentes conservan visibilidad: el nuevo estado nace como 'activo'.
-- El estado solo puede cambiarse desde las funciones privadas de administración.

alter table public.comercios
  add column if not exists estado_publicacion text not null default 'activo';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'comercios_estado_publicacion_check'
      and conrelid = 'public.comercios'::regclass
  ) then
    alter table public.comercios
      add constraint comercios_estado_publicacion_check
      check (estado_publicacion in ('activo','pausado','suspendido'));
  end if;
end
$$;

create or replace function private.usuario_es_admin_encontralo_ya()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    where u.id = auth.uid()
      and u.email_confirmed_at is not null
      and lower(u.email) = 'administracionencontraloya@gmail.com'
  );
$$;
revoke all on function private.usuario_es_admin_encontralo_ya() from public, anon, authenticated;

create or replace function private.proteger_estado_publicacion_comercio()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.usuario_es_admin_encontralo_ya() then
    if tg_op = 'INSERT' then
      new.estado_publicacion := 'activo';
    elsif new.estado_publicacion is distinct from old.estado_publicacion then
      raise exception 'Solo administración puede cambiar el estado de publicación del comercio.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.proteger_estado_publicacion_comercio() from public, anon, authenticated;

drop trigger if exists proteger_estado_publicacion_comercio on public.comercios;
create trigger proteger_estado_publicacion_comercio
before insert or update of estado_publicacion on public.comercios
for each row execute function private.proteger_estado_publicacion_comercio();

create or replace function public.listar_comercios_administracion()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  if not private.usuario_es_admin_encontralo_ya() then
    raise exception 'Acceso reservado a administración' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'nombre', c.nombre, 'rubro', c.rubro,
    'localidad', c.localidad, 'provincia', c.provincia,
    'telefono', c.telefono, 'contacto', c.contacto,
    'que_vende', c.que_vende, 'propietario_id', c.propietario_id,
    'estado_publicacion', c.estado_publicacion, 'fecha', c.created_at,
    'productos_total', (select count(*)::integer from public.productos p where p.comercio_id = c.id)
  ) order by c.created_at desc), '[]'::jsonb)
  into v_result from public.comercios c;
  return v_result;
end;
$$;
revoke all on function public.listar_comercios_administracion() from public, anon;
grant execute on function public.listar_comercios_administracion() to authenticated;

create or replace function public.administrar_estado_comercio(p_comercio_id uuid, p_estado text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_nombre text;
begin
  if not private.usuario_es_admin_encontralo_ya() then
    raise exception 'Acceso reservado a administración' using errcode = '42501';
  end if;
  if p_estado not in ('activo','pausado','suspendido') then
    raise exception 'Estado de comercio no válido.' using errcode = '22023';
  end if;
  update public.comercios set estado_publicacion = p_estado
  where id = p_comercio_id returning nombre into v_nombre;
  if not found then
    raise exception 'No encontramos ese comercio.' using errcode = 'P0002';
  end if;
  return jsonb_build_object('ok', true, 'nombre', v_nombre, 'estado', p_estado);
end;
$$;
revoke all on function public.administrar_estado_comercio(uuid,text) from public, anon;
grant execute on function public.administrar_estado_comercio(uuid,text) to authenticated;

drop policy if exists "Comercios visibles" on public.comercios;
drop policy if exists "Lectura publica comercios" on public.comercios;
drop policy if exists "Lectura publica de comercios" on public.comercios;
create policy "Comercios activos visibles publicamente"
on public.comercios for select to anon, authenticated
using (estado_publicacion = 'activo');

drop policy if exists "Lectura publica de productos" on public.productos;
drop policy if exists "Lectura publica productos" on public.productos;
drop policy if exists "Productos visibles" on public.productos;
create policy "Productos de comercios activos visibles"
on public.productos for select to anon, authenticated
using (exists (
  select 1 from public.comercios c
  where c.id = productos.comercio_id
    and c.estado_publicacion = 'activo'
));

-- Acceso de lectura limitado a las columnas públicas que usa el catálogo.
grant select (id,nombre,localidad,provincia,telefono,cobertura_localidades,estado_publicacion)
on public.comercios to anon, authenticated;
