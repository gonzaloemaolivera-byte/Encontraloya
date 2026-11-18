-- Pruebas del bloqueo de renovación OAuth.
DO $$
DECLARE
  v_first uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  v_second uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  v_acquired boolean;
BEGIN
  IF NOT public.mp_try_lock_token_refresh(
    '10000000-0000-4000-8000-000000000001', v_first, 45
  ) THEN
    RAISE EXCEPTION 'El primer proceso no pudo adquirir el bloqueo';
  END IF;

  IF public.mp_try_lock_token_refresh(
    '10000000-0000-4000-8000-000000000001', v_second, 45
  ) THEN
    RAISE EXCEPTION 'Dos procesos adquirieron simultáneamente el mismo bloqueo';
  END IF;

  IF public.mp_release_token_refresh_lock(
    '10000000-0000-4000-8000-000000000001', v_second
  ) THEN
    RAISE EXCEPTION 'Un proceso pudo liberar el bloqueo de otro';
  END IF;

  IF NOT public.mp_release_token_refresh_lock(
    '10000000-0000-4000-8000-000000000001', v_first
  ) THEN
    RAISE EXCEPTION 'El propietario no pudo liberar su bloqueo';
  END IF;

  IF NOT public.mp_try_lock_token_refresh(
    '10000000-0000-4000-8000-000000000001', v_second, 45
  ) THEN
    RAISE EXCEPTION 'El segundo proceso no pudo adquirir un bloqueo liberado';
  END IF;

  UPDATE public.mercado_pago_refresh_locks
  SET locked_until = clock_timestamp() - interval '1 second'
  WHERE comercio_id = '10000000-0000-4000-8000-000000000001';

  IF NOT public.mp_try_lock_token_refresh(
    '10000000-0000-4000-8000-000000000001', v_first, 45
  ) THEN
    RAISE EXCEPTION 'No se pudo recuperar un bloqueo vencido';
  END IF;

  IF public.mp_release_token_refresh_lock(
    '10000000-0000-4000-8000-000000000001', v_second
  ) THEN
    RAISE EXCEPTION 'Un propietario anterior liberó el bloqueo nuevo';
  END IF;

  IF NOT public.mp_release_token_refresh_lock(
    '10000000-0000-4000-8000-000000000001', v_first
  ) THEN
    RAISE EXCEPTION 'No se pudo liberar el bloqueo recuperado';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_function_privilege('anon',
    'public.mp_try_lock_token_refresh(uuid,uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar el bloqueo de refresh';
  END IF;
  IF has_function_privilege('authenticated',
    'public.mp_try_lock_token_refresh(uuid,uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated puede ejecutar el bloqueo de refresh';
  END IF;
  IF NOT has_function_privilege('service_role',
    'public.mp_try_lock_token_refresh(uuid,uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role no puede ejecutar el bloqueo de refresh';
  END IF;
END;
$$;
