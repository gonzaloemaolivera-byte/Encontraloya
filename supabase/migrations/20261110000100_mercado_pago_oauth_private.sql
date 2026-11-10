-- Mercado Pago Split 1:1: almacenamiento privado de OAuth.
-- Tablas en public por compatibilidad con PostgREST; RLS y GRANTs impiden acceso
-- a anon/authenticated. Solo service_role puede operar estas tablas.
create table if not exists public.mercado_pago_tokens_privado (
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

create table if not exists public.mercado_pago_oauth_states_privado (
  state_hash text primary key,
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  propietario_id uuid not null references auth.users(id) on delete cascade,
  creado_at timestamptz not null default now(),
  expira_at timestamptz not null,
  usado_at timestamptz
);

alter table public.mercado_pago_tokens_privado enable row level security;
alter table public.mercado_pago_oauth_states_privado enable row level security;

revoke all on public.mercado_pago_tokens_privado from public, anon, authenticated;
revoke all on public.mercado_pago_oauth_states_privado from public, anon, authenticated;
grant all on public.mercado_pago_tokens_privado to service_role;
grant all on public.mercado_pago_oauth_states_privado to service_role;

create index if not exists mercado_pago_oauth_states_privado_expira_idx
  on public.mercado_pago_oauth_states_privado (expira_at);
