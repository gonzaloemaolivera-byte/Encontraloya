-- Entorno descartable para probar exclusivamente la RPC del webhook.
-- No contiene datos reales, secretos ni conexiones a Supabase.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);

CREATE TABLE public.comercios (
  id uuid PRIMARY KEY
);

CREATE TABLE public.pedidos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  numero_pedido bigint NOT NULL UNIQUE,
  comercio_id uuid NOT NULL REFERENCES public.comercios(id) ON DELETE RESTRICT,
  comprador_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  estado text NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente','confirmado','preparando','listo','enviado','completado','cancelado','reembolsado')),
  moneda text NOT NULL DEFAULT 'ARS' CHECK (moneda = 'ARS'),
  subtotal numeric NOT NULL CHECK (subtotal >= 0),
  costo_envio numeric NOT NULL DEFAULT 0 CHECK (costo_envio >= 0),
  total numeric NOT NULL CHECK (total >= 0 AND total = subtotal + costo_envio),
  creado_at timestamptz NOT NULL DEFAULT now(),
  actualizado_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.pagos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id uuid NOT NULL REFERENCES public.pedidos(id) ON DELETE RESTRICT,
  medio_pago text NOT NULL CHECK (medio_pago IN ('mercado_pago','efectivo','tarjeta_credito','tarjeta_debito','cheque')),
  proveedor text NOT NULL DEFAULT 'manual' CHECK (proveedor IN ('mercado_pago','manual')),
  estado text NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente','aprobado','rechazado','cancelado','reembolsado','reembolso_parcial','en_disputa')),
  importe numeric NOT NULL CHECK (importe > 0),
  moneda text NOT NULL DEFAULT 'ARS' CHECK (moneda = 'ARS'),
  referencia_externa text,
  idempotencia text UNIQUE,
  fecha_confirmacion timestamptz,
  datos_operativos jsonb NOT NULL DEFAULT '{}'::jsonb,
  creado_at timestamptz NOT NULL DEFAULT now(),
  actualizado_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (proveedor, referencia_externa)
);

CREATE TABLE public.comisiones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id uuid NOT NULL UNIQUE REFERENCES public.pedidos(id) ON DELETE RESTRICT,
  porcentaje numeric NOT NULL CHECK (porcentaje >= 0 AND porcentaje <= 100),
  base_calculo numeric NOT NULL CHECK (base_calculo >= 0),
  importe_comision numeric NOT NULL CHECK (importe_comision >= 0),
  moneda text NOT NULL DEFAULT 'ARS' CHECK (moneda = 'ARS'),
  estado text NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente','devengada','cobrada','liquidada','revertida')),
  importe_cobrado numeric NOT NULL DEFAULT 0 CHECK (importe_cobrado >= 0),
  creado_at timestamptz NOT NULL DEFAULT now(),
  actualizado_at timestamptz NOT NULL DEFAULT now()
);

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
