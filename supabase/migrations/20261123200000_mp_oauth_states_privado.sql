-- Encontralo Ya: estados de un solo uso para el flujo OAuth de Mercado Pago.
-- La tabla guarda solo el hash SHA-256 del estado aleatorio que conecta a un
-- titular con un comercio mientras dura la autorización (10 minutos).
-- Idempotente: no toca comercios, productos, pedidos, usuarios ni otras
-- tablas, y no borra ningún dato.

BEGIN;

CREATE TABLE IF NOT EXISTS public.mercado_pago_oauth_states_privado (
  state_hash text PRIMARY KEY,
  comercio_id uuid NOT NULL REFERENCES public.comercios(id),
  propietario_id uuid NOT NULL REFERENCES auth.users(id),
  creado_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  expira_at timestamptz NOT NULL,
  usado_at timestamptz
);

-- Solo el service_role de las Edge Functions (mp-oauth-start y
-- mp-oauth-callback) debe poder leer y escribir estados: RLS sin políticas
-- niega todo acceso a anon y authenticated.
ALTER TABLE public.mercado_pago_oauth_states_privado ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mercado_pago_oauth_states_privado FORCE ROW LEVEL SECURITY;

REVOKE ALL ON public.mercado_pago_oauth_states_privado
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.mercado_pago_oauth_states_privado TO service_role;

COMMIT;
