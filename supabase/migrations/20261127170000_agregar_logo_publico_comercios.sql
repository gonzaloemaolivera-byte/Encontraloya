alter table public.comercios
  add column if not exists logo_url text;

comment on column public.comercios.logo_url is
  'URL pública del logo o imagen representativa del comercio. Opcional.';
