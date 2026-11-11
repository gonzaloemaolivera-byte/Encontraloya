-- Autorización privada y temporal para iniciar el checkout de un pedido.
create table if not exists public.checkout_tokens_privado (
 pedido_id uuid primary key references public.pedidos(id) on delete cascade,
 token_hash text not null unique,
 expira_at timestamptz not null,
 creado_at timestamptz not null default now()
);
alter table public.checkout_tokens_privado enable row level security;
revoke all on public.checkout_tokens_privado from public, anon, authenticated;
grant all on public.checkout_tokens_privado to service_role;
create index if not exists checkout_tokens_privado_expira_idx on public.checkout_tokens_privado (expira_at);
