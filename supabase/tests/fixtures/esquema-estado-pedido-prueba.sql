-- Esquema reducido de prueba para el circuito de estado de pedidos y
-- conexión de Mercado Pago. No contiene datos reales ni credenciales.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS private;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text NOT NULL,
  email_confirmed_at timestamptz
);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('00000000-0000-4000-8000-000000000001', 'titular@example.test', now()),
  ('00000000-0000-4000-8000-000000000002', 'otro@example.test', now()),
  ('00000000-0000-4000-8000-000000000003', 'sinconfirmar@example.test', NULL);

CREATE TABLE public.comercios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre text NOT NULL,
  propietario_id uuid REFERENCES auth.users(id)
);

CREATE TABLE public.pedidos (
  id uuid PRIMARY KEY,
  numero_pedido int NOT NULL,
  estado text NOT NULL DEFAULT 'pendiente',
  subtotal numeric(12,2),
  total numeric(12,2),
  moneda text NOT NULL DEFAULT 'ARS',
  comercio_id uuid REFERENCES public.comercios(id),
  comprador_nombre text,
  comprador_email text,
  comprador_telefono text,
  direccion_entrega text,
  notas text,
  creado_at timestamptz NOT NULL DEFAULT now(),
  actualizado_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.pagos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id uuid REFERENCES public.pedidos(id),
  estado text NOT NULL,
  medio_pago text,
  importe numeric(12,2),
  moneda text NOT NULL DEFAULT 'ARS',
  creado_at timestamptz NOT NULL DEFAULT now(),
  actualizado_at timestamptz NOT NULL DEFAULT now()
);

-- Almacén de tokens de checkout (hash SHA-256 por pedido).
CREATE TABLE public.checkout_tokens_privado (
  pedido_id uuid PRIMARY KEY,
  token_hash text NOT NULL,
  expira_at timestamptz NOT NULL DEFAULT now() + interval '1 day',
  creado_at timestamptz NOT NULL DEFAULT now()
);

-- Códigos de reclamo de comercios: el escaneo del estado de conexión y de
-- tokens NO debe confundir estos datos con credenciales de Mercado Pago.
CREATE TABLE public.comercio_codigos_reclamo (
  comercio_id uuid PRIMARY KEY,
  codigo_hash text NOT NULL
);

-- Credenciales OAuth de Mercado Pago por comercio.
CREATE TABLE public.mercado_pago_tokens_privado (
  comercio_id uuid PRIMARY KEY,
  access_token_enc text NOT NULL,
  refresh_token_enc text NOT NULL,
  public_key text,
  live_mode boolean NOT NULL DEFAULT false,
  scope text,
  expires_at timestamptz,
  actualizado_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.conexiones_mercado_pago (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comercio_id uuid NOT NULL UNIQUE,
  usuario_mercado_pago_id text,
  estado text NOT NULL DEFAULT 'conectado',
  alcance_autorizado text[],
  conectado_at timestamptz,
  desconectado_at timestamptz,
  creado_at timestamptz NOT NULL DEFAULT now(),
  actualizado_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.configuracion_plataforma (
  id integer PRIMARY KEY,
  porcentaje_comision numeric NOT NULL DEFAULT 5,
  actualizado_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.configuracion_plataforma(id, porcentaje_comision) VALUES (1,5);

-- Datos de prueba
INSERT INTO public.comercios (id, nombre, propietario_id) VALUES
  ('00000000-0000-4000-8000-000000000101', 'Ferretería Conectada', '00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000102', 'Comercio Sin MP', '00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000103', 'Comercio De Otro', '00000000-0000-4000-8000-000000000002');

INSERT INTO public.pedidos (id, numero_pedido, estado, subtotal, total, moneda, comercio_id, comprador_nombre, comprador_email)
VALUES ('00000000-0000-4000-8000-000000000201', 9001, 'pendiente', 55.50, 55.50, 'ARS',
        '00000000-0000-4000-8000-000000000101', 'Comprador Prueba', 'comprador@example.test');

INSERT INTO public.checkout_tokens_privado (pedido_id, token_hash)
VALUES ('00000000-0000-4000-8000-000000000201',
        encode(sha256(convert_to(repeat('a', 64), 'UTF8')), 'hex'));

INSERT INTO public.pagos (pedido_id, estado, medio_pago, importe, moneda)
VALUES ('00000000-0000-4000-8000-000000000201', 'pendiente', 'mercado_pago', 55.50, 'ARS');

INSERT INTO public.mercado_pago_tokens_privado (comercio_id, access_token_enc, refresh_token_enc, public_key)
VALUES ('00000000-0000-4000-8000-000000000101', 'cifrado', 'refresh-cifrado', 'TEST-123');
INSERT INTO public.conexiones_mercado_pago (comercio_id, estado)
VALUES ('00000000-0000-4000-8000-000000000101', 'conectado');

-- Código de reclamo pendiente de OTRO comercio: no debe dar falso positivo.
INSERT INTO public.comercio_codigos_reclamo (comercio_id, codigo_hash)
VALUES ('00000000-0000-4000-8000-000000000103', 'hash-reclamo');
