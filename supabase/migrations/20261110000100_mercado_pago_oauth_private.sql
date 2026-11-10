-- Mercado Pago Split 1:1: almacenamiento privado de OAuth.
-- Los tokens nunca se exponen al navegador ni a los roles anon/authenticated.
create schema if not exists private;

create table if not exists private.mercado_pago_tokens (
  comercio_id uuid primary key references public.comercios(id) on delete cascade,
  usuario_mercado_pago_id text not null,
  access_token_enc text not null,
  refresh_token_enc text not null,
  public_key text,
  live_mode boolean not null default false,
  scope text,
  expires_at timestamptz not null,
  actualizado_at timestamptz not null default now()
);

create table if not exists private.mercado_pago_oauth_states (
  state_hash text primary key,
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  propietario_id uuid not null references auth.users(id) on delete cascade,
  creado_at timestamptz not null default now(),
  expira_at timestamptz not null,
  usado_at timestamptz
);

alter table private.mercado_pago_tokens enable row level security;
alter table private.mercado_pago_oauth_states enable row level security;

revoke all on private.mercado_pago_tokens from public, anon, authenticated;
revoke all on private.mercado_pago_oauth_states from public, anon, authenticated;
grant usage on schema private to service_role;
grant select, insert, update, delete on private.mercado_pago_tokens to service_role;
grant select, insert, update, delete on private.mercado_pago_oauth_states to service_role;

create index if not exists mercado_pago_oauth_states_expira_idx
  on private.mercado_pago_oauth_states (expira_at);
