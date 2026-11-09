-- Esquema reducido de prueba. No contiene datos reales ni credenciales.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;
CREATE SCHEMA private;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text NOT NULL,
  email_confirmed_at timestamptz
);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
('00000000-0000-4000-8000-000000000001', 'titular1@example.test', now()),
('00000000-0000-4000-8000-000000000002', 'titular2@example.test', now()),
('00000000-0000-4000-8000-000000000003', 'sinconfirmar@example.test', NULL);

CREATE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;

CREATE TABLE private.comercio_vinculaciones (
  comercio_id uuid PRIMARY KEY,
  codigo text NOT NULL UNIQUE
);
ALTER TABLE private.comercio_vinculaciones ENABLE ROW LEVEL SECURITY;

CREATE SEQUENCE public.codigo_vendedor_seq;

CREATE TABLE public.comercios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre text NOT NULL,
  rubro text,
  localidad text,
  provincia text,
  telefono text,
  direccion text,
  created_at timestamptz DEFAULT now(),
  contacto text,
  que_vende text,
  propietario_id uuid REFERENCES auth.users(id),
  codigo_vendedor text NOT NULL DEFAULT ''
);

CREATE TABLE public.productos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comercio_id uuid REFERENCES public.comercios(id),
  nombre text NOT NULL,
  descripcion text,
  categoria text,
  precio numeric,
  moneda text DEFAULT 'ARS',
  disponible boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.comercios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Lectura publica comercios" ON public.comercios
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Registro publico de comercios" ON public.comercios
  FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "Propietarios ven sus comercios" ON public.comercios
  FOR SELECT TO authenticated USING (propietario_id = auth.uid());
CREATE POLICY "Propietarios modifican sus comercios" ON public.comercios
  FOR UPDATE TO authenticated
  USING (propietario_id = auth.uid())
  WITH CHECK (propietario_id = auth.uid());
CREATE POLICY "Lectura publica productos" ON public.productos
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Propietarios administran productos" ON public.productos
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.comercios c
    WHERE c.id = productos.comercio_id AND c.propietario_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.comercios c
    WHERE c.id = productos.comercio_id AND c.propietario_id = auth.uid()
  ));

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.comercios, public.productos TO anon, authenticated;
GRANT INSERT ON public.comercios TO anon;
GRANT INSERT, UPDATE, SELECT ON public.productos TO authenticated;

CREATE FUNCTION public.generar_codigo_vendedor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.codigo_vendedor IS NULL OR btrim(NEW.codigo_vendedor) = '' THEN
    NEW.codigo_vendedor := 'VEN-' || lpad(nextval('public.codigo_vendedor_seq')::text, 6, '0');
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.generar_codigo_vinculacion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $$
BEGIN
  INSERT INTO private.comercio_vinculaciones (comercio_id, codigo)
  VALUES (NEW.id, upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)));
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.vincular_comercio(p_codigo text)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT NULL::uuid;
$$;

CREATE TRIGGER asignar_codigo_vendedor
BEFORE INSERT ON public.comercios
FOR EACH ROW EXECUTE FUNCTION public.generar_codigo_vendedor();

CREATE TRIGGER generar_codigo_vinculacion
AFTER INSERT ON public.comercios
FOR EACH ROW EXECUTE FUNCTION public.generar_codigo_vinculacion();

GRANT EXECUTE ON FUNCTION public.vincular_comercio(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generar_codigo_vendedor() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generar_codigo_vinculacion() TO anon, authenticated;

CREATE FUNCTION public.encontralo_normalizar_telefono_v1(telefono text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(regexp_replace(COALESCE(telefono, ''), '[^0-9]', '', 'g'), '');
$$;

CREATE FUNCTION public.telefono_argentino_clave(p_telefono text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
  SELECT regexp_replace(COALESCE(p_telefono, ''), '[^0-9]', '', 'g');
$$;

INSERT INTO public.comercios (nombre, rubro, localidad, provincia, telefono)
SELECT 'Comercio ' || g.n, 'Ferretería', 'Moreno', 'Buenos Aires', '11 2345-678' || g.n
FROM generate_series(1, 7) AS g(n);

INSERT INTO public.productos (comercio_id, nombre, descripcion, categoria, precio, moneda, disponible)
SELECT c.id, 'Producto ' || n, 'Producto de prueba', 'Ferretería', n * 100, 'ARS', true
FROM public.comercios c
JOIN generate_series(1, 4) AS g(n) ON c.nombre = 'Comercio ' || g.n;

CREATE VIEW public.encontralo_revision_telefonos_v1 AS
SELECT id, nombre, telefono,
       public.encontralo_normalizar_telefono_v1(telefono) AS telefono_normalizado,
       count(*) OVER (PARTITION BY public.encontralo_normalizar_telefono_v1(telefono)) AS cantidad_con_mismo_telefono
FROM public.comercios
WHERE telefono IS NOT NULL
  AND public.encontralo_normalizar_telefono_v1(telefono) IS NOT NULL;

GRANT ALL ON public.encontralo_revision_telefonos_v1 TO anon, authenticated;
