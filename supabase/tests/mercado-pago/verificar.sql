\set ON_ERROR_STOP on

INSERT INTO public.comercios (id) VALUES
('10000000-0000-4000-8000-000000000001');

INSERT INTO public.pedidos
  (id, numero_pedido, comercio_id, estado, moneda, subtotal, costo_envio, total)
VALUES
  ('20000000-0000-4000-8000-000000000001', 9001,
   '10000000-0000-4000-8000-000000000001', 'pendiente', 'ARS', 1000, 0, 1000),
  ('20000000-0000-4000-8000-000000000002', 9002,
   '10000000-0000-4000-8000-000000000001', 'pendiente', 'ARS', 2000, 0, 2000),
  ('20000000-0000-4000-8000-000000000003', 9003,
   '10000000-0000-4000-8000-000000000001', 'pendiente', 'ARS', 3000, 0, 3000);

INSERT INTO public.comisiones
  (pedido_id, porcentaje, base_calculo, importe_comision, moneda, estado)
VALUES
  ('20000000-0000-4000-8000-000000000001', 5, 1000, 50, 'ARS', 'pendiente'),
  ('20000000-0000-4000-8000-000000000002', 5, 2000, 100, 'ARS', 'pendiente');

-- Aprobación: pago, pedido y comisión deben cambiar juntos.
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-9001', 'approved', 1000, 'ARS', false, now(), '{"test":true}'::jsonb
);

DO $$
BEGIN
  IF (SELECT estado FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 'aprobado' THEN
    RAISE EXCEPTION 'El pago no quedó aprobado';
  END IF;
  IF (SELECT estado FROM public.pedidos WHERE id='20000000-0000-4000-8000-000000000001') <> 'confirmado' THEN
    RAISE EXCEPTION 'El pedido no quedó confirmado';
  END IF;
  IF (SELECT estado FROM public.comisiones WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 'cobrada'
     OR (SELECT importe_cobrado FROM public.comisiones WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 50 THEN
    RAISE EXCEPTION 'La comisión del 5%% no quedó cobrada correctamente';
  END IF;
END;
$$;

-- Repetición de la notificación: no debe duplicar ni degradar el pago.
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-9001', 'approved', 1000, 'ARS', false, now(), '{"duplicate":true}'::jsonb
);
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-9001', 'pending', 1000, 'ARS', false, NULL, '{"late":true}'::jsonb
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 1 THEN
    RAISE EXCEPTION 'Se duplicó el registro de pago';
  END IF;
  IF (SELECT estado FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 'aprobado' THEN
    RAISE EXCEPTION 'Una notificación tardía degradó el pago';
  END IF;
END;
$$;

-- Importe incorrecto: debe fallar sin insertar ni cambiar estados.
DO $$
BEGIN
  BEGIN
    PERFORM public.procesar_pago_mercado_pago_webhook(
      '20000000-0000-4000-8000-000000000002',
      '10000000-0000-4000-8000-000000000001',
      'mp-test-wrong-amount', 'approved', 1999, 'ARS', false, now(), '{}'::jsonb
    );
    RAISE EXCEPTION 'Se aceptó un importe incorrecto';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Se aceptó un importe incorrecto' THEN RAISE; END IF;
  END;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Se guardó un pago con importe incorrecto';
  END IF;
  IF (SELECT estado FROM public.pedidos WHERE id='20000000-0000-4000-8000-000000000002') <> 'pendiente' THEN
    RAISE EXCEPTION 'Cambió el pedido tras un importe incorrecto';
  END IF;
END;
$$;

-- Sin comisión asociada, no se debe confirmar ni registrar el pago.
DO $$
BEGIN
  BEGIN
    PERFORM public.procesar_pago_mercado_pago_webhook(
      '20000000-0000-4000-8000-000000000003',
      '10000000-0000-4000-8000-000000000001',
      'mp-test-no-commission', 'approved', 3000, 'ARS', false, now(), '{}'::jsonb
    );
    RAISE EXCEPTION 'Se aprobó un pedido sin comisión asociada';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Se aprobó un pedido sin comisión asociada' THEN RAISE; END IF;
  END;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000003') THEN
    RAISE EXCEPTION 'Se guardó un pago sin comisión asociada';
  END IF;
  IF (SELECT estado FROM public.pedidos WHERE id='20000000-0000-4000-8000-000000000003') <> 'pendiente' THEN
    RAISE EXCEPTION 'Se confirmó un pedido sin comisión asociada';
  END IF;
END;
$$;

-- Una autorización no capturada no confirma el pedido ni cobra comisión.
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-authorized-9002', 'authorized', 2000, 'ARS', false, NULL, '{}'::jsonb
);

DO $$
BEGIN
  IF (SELECT estado FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000002') <> 'pendiente' THEN
    RAISE EXCEPTION 'Una autorización se trató como pago capturado';
  END IF;
  IF (SELECT estado FROM public.pedidos WHERE id='20000000-0000-4000-8000-000000000002') <> 'pendiente'
     OR (SELECT estado FROM public.comisiones WHERE pedido_id='20000000-0000-4000-8000-000000000002') <> 'pendiente' THEN
    RAISE EXCEPTION 'Una autorización confirmó el pedido o cobró la comisión';
  END IF;
END;
$$;

-- Una mediación debe quedar en disputa, sin convertirla en venta cobrada.
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-authorized-9002', 'in_mediation', 2000, 'ARS', false, NULL, '{}'::jsonb
);

DO $$
BEGIN
  IF (SELECT estado FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000002') <> 'en_disputa' THEN
    RAISE EXCEPTION 'La mediación no quedó en disputa';
  END IF;
  IF (SELECT estado FROM public.pedidos WHERE id='20000000-0000-4000-8000-000000000002') <> 'pendiente'
     OR (SELECT estado FROM public.comisiones WHERE pedido_id='20000000-0000-4000-8000-000000000002') <> 'pendiente' THEN
    RAISE EXCEPTION 'La mediación fue tratada como una venta confirmada';
  END IF;
END;
$$;

-- El mismo ID externo no se puede asociar a otro pedido.
DO $$
BEGIN
  BEGIN
    PERFORM public.procesar_pago_mercado_pago_webhook(
      '20000000-0000-4000-8000-000000000002',
      '10000000-0000-4000-8000-000000000001',
      'mp-test-9001', 'approved', 2000, 'ARS', false, now(), '{}'::jsonb
    );
    RAISE EXCEPTION 'Se reutilizó el ID de pago en otro pedido';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Se reutilizó el ID de pago en otro pedido' THEN RAISE; END IF;
  END;
END;
$$;

-- Reembolso y notificación antigua: no debe volver a marcarse como aprobado.
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-9001', 'refunded', 1000, 'ARS', false, now(), '{"refund":true}'::jsonb
);
SELECT public.procesar_pago_mercado_pago_webhook(
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'mp-test-9001', 'approved', 1000, 'ARS', false, now(), '{"late_approval":true}'::jsonb
);

DO $$
BEGIN
  IF (SELECT estado FROM public.pagos WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 'reembolsado' THEN
    RAISE EXCEPTION 'El reembolso no quedó registrado';
  END IF;
  IF (SELECT estado FROM public.pedidos WHERE id='20000000-0000-4000-8000-000000000001') <> 'reembolsado' THEN
    RAISE EXCEPTION 'El pedido no quedó reembolsado';
  END IF;
  IF (SELECT estado FROM public.comisiones WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 'revertida'
     OR (SELECT importe_cobrado FROM public.comisiones WHERE pedido_id='20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'La comisión no se revirtió correctamente';
  END IF;
END;
$$;

-- La RPC solo puede ejecutarla service_role.
DO $$
BEGIN
  IF has_function_privilege('anon',
    'public.procesar_pago_mercado_pago_webhook(uuid,uuid,text,text,numeric,text,boolean,timestamptz,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'La RPC quedó expuesta a anon';
  END IF;
  IF has_function_privilege('authenticated',
    'public.procesar_pago_mercado_pago_webhook(uuid,uuid,text,text,numeric,text,boolean,timestamptz,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'La RPC quedó expuesta a authenticated';
  END IF;
  IF NOT has_function_privilege('service_role',
    'public.procesar_pago_mercado_pago_webhook(uuid,uuid,text,text,numeric,text,boolean,timestamptz,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role no puede ejecutar la RPC';
  END IF;
END;
$$;

SELECT 'OK: pruebas SQL del webhook completadas' AS resultado;
