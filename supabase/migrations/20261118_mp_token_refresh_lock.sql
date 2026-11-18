-- Serializa la renovación de tokens OAuth por comercio.
-- Aplicar solo después de validar en el entorno aislado; NO desplegar a producción todavía.

create table if not exists public.mercado_pago_refresh_locks (
  comercio_id uuid primary key,
  lock_token uuid not null,
  locked_until timestamptz not null,
  creado_at timestamptz not null default now(),
  actualizado_at timestamptz not null default now()
);

alter table public.mercado_pago_refresh_locks enable row level security;
revoke all on table public.mercado_pago_refresh_locks from public, anon, authenticated;
grant select, insert, update, delete on table public.mercado_pago_refresh_locks to service_role;

create or replace function public.mp_try_lock_token_refresh(
  p_comercio_id uuid,
  p_lock_token uuid,
  p_lease_seconds integer default 45
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_acquired boolean := false;
  v_lease integer := least(greatest(coalesce(p_lease_seconds,45),15),120);
begin
  if p_comercio_id is null or p_lock_token is null then
    raise exception 'comercio_id y lock_token son obligatorios';
  end if;

  insert into public.mercado_pago_refresh_locks
    (comercio_id, lock_token, locked_until, actualizado_at)
  values
    (p_comercio_id, p_lock_token, clock_timestamp() + make_interval(secs => v_lease), clock_timestamp())
  on conflict (comercio_id) do update
    set lock_token = excluded.lock_token,
        locked_until = excluded.locked_until,
        actualizado_at = clock_timestamp()
    where public.mercado_pago_refresh_locks.locked_until < clock_timestamp()
  returning true into v_acquired;

  return coalesce(v_acquired, false);
end;
$$;

create or replace function public.mp_release_token_refresh_lock(
  p_comercio_id uuid,
  p_lock_token uuid
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_deleted boolean := false;
begin
  delete from public.mercado_pago_refresh_locks
  where comercio_id = p_comercio_id and lock_token = p_lock_token
  returning true into v_deleted;
  return coalesce(v_deleted, false);
end;
$$;

revoke all on function public.mp_try_lock_token_refresh(uuid,uuid,integer)
  from public, anon, authenticated;
revoke all on function public.mp_release_token_refresh_lock(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.mp_try_lock_token_refresh(uuid,uuid,integer)
  to service_role;
grant execute on function public.mp_release_token_refresh_lock(uuid,uuid)
  to service_role;
