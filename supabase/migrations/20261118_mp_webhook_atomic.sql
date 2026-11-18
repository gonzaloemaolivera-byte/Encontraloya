-- BORRADOR: no ejecutar en producción hasta revisión y pruebas sandbox.
-- Procesa en una sola transacción la actualización de pago, pedido y comisión.
-- La función solo debe poder ser invocada por service_role desde el webhook.

create or replace function public.procesar_pago_mercado_pago_webhook(
  p_pedido_id uuid,
  p_comercio_id uuid,
  p_payment_id text,
  p_payment_status text,
  p_importe numeric,
  p_moneda text,
  p_live_mode boolean,
  p_fecha_aprobacion timestamptz,
  p_datos_operativos jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_pedido public.pedidos%rowtype;
  v_pago public.pagos%rowtype;
  v_estado text;
  v_actualizado boolean := false;
begin
  if p_pedido_id is null or p_comercio_id is null
     or coalesce(trim(p_payment_id),'') = ''
     or p_importe is null or p_importe <= 0
     or p_moneda <> 'ARS'
     or p_live_mode is null then
    raise exception 'Datos de pago incompletos o inválidos';
  end if;

  select * into v_pedido
  from public.pedidos
  where id = p_pedido_id and comercio_id = p_comercio_id
  for update;

  if not found then
    raise exception 'Pedido o comercio no coinciden';
  end if;

  if abs(v_pedido.total - p_importe) > 0.01 or v_pedido.moneda <> p_moneda then
    raise exception 'El importe o moneda no coincide con el pedido';
  end if;

  -- Impide asociar el mismo ID de pago a otro pedido.
  if exists (
    select 1 from public.pagos
    where proveedor = 'mercado_pago'
      and referencia_externa = p_payment_id
      and pedido_id <> p_pedido_id
  ) then
    raise exception 'El pago ya está asociado a otro pedido';
  end if;

  select * into v_pago
  from public.pagos
  where idempotencia = 'mp-order-' || p_pedido_id::text
  for update;

  if found and v_pago.proveedor <> 'mercado_pago' then
    raise exception 'El pedido ya tiene un registro de pago de otro proveedor';
  end if;

  v_estado := case p_payment_status
    when 'approved' then 'aprobado'
    when 'authorized' then 'pendiente'
    when 'in_mediation' then 'en_disputa'
    when 'rejected' then 'rechazado'
    when 'cancelled' then 'cancelado'
    when 'refunded' then 'reembolsado'
    when 'charged_back' then 'en_disputa'
    when 'in_process' then 'pendiente'
    when 'pending' then 'pendiente'
    else null
  end;

  if v_estado is null then
    raise exception 'Estado de Mercado Pago no reconocido';
  end if;

  -- No permitir que una notificación tardía rebaje un pago aprobado,
  -- ni que un evento posterior revierta un reembolso ya registrado.
  if found and v_pago.estado in ('aprobado','reembolsado')
     and v_estado not in ('reembolsado','en_disputa') then
    return jsonb_build_object('ok', true, 'duplicado_o_antiguo', true, 'estado', v_pago.estado);
  end if;

  if found and v_pago.estado = 'reembolsado' then
    return jsonb_build_object('ok', true, 'duplicado_o_antiguo', true, 'estado', 'reembolsado');
  end if;

  insert into public.pagos (
    pedido_id, medio_pago, proveedor, estado, importe, moneda,
    referencia_externa, idempotencia, fecha_confirmacion,
    datos_operativos, actualizado_at
  ) values (
    p_pedido_id, 'mercado_pago', 'mercado_pago', v_estado, p_importe, p_moneda,
    p_payment_id, 'mp-order-' || p_pedido_id::text,
    case when v_estado = 'aprobado' then coalesce(p_fecha_aprobacion, now()) else null end,
    coalesce(p_datos_operativos, '{}'::jsonb), now()
  )
  on conflict (idempotencia) do update set
    estado = excluded.estado,
    importe = excluded.importe,
    moneda = excluded.moneda,
    referencia_externa = excluded.referencia_externa,
    fecha_confirmacion = case
      when excluded.estado = 'aprobado' then coalesce(excluded.fecha_confirmacion, now())
      else public.pagos.fecha_confirmacion
    end,
    datos_operativos = coalesce(public.pagos.datos_operativos, '{}'::jsonb) || excluded.datos_operativos,
    actualizado_at = now();

  if v_estado = 'aprobado' then
    update public.pedidos
      set estado = case when estado = 'pendiente' then 'confirmado' else estado end,
          actualizado_at = now()
      where id = p_pedido_id;

    update public.comisiones
      set estado = case when estado in ('pendiente','devengada') then 'cobrada' else estado end,
          importe_cobrado = case when estado in ('pendiente','devengada') then importe_comision else importe_cobrado end,
          actualizado_at = now()
      where pedido_id = p_pedido_id;
    if not found then
      raise exception 'No existe una comisión asociada al pedido';
    end if;
  elsif v_estado = 'reembolsado' then
    update public.pedidos
      set estado = 'reembolsado', actualizado_at = now()
      where id = p_pedido_id;

    update public.comisiones
      set estado = 'revertida', importe_cobrado = 0, actualizado_at = now()
      where pedido_id = p_pedido_id;
    if not found then
      raise exception 'No existe una comisión asociada al pedido';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'estado', v_estado, 'pedido_id', p_pedido_id);
end;
$$;

revoke all on function public.procesar_pago_mercado_pago_webhook(
  uuid, uuid, text, text, numeric, text, boolean, timestamptz, jsonb
) from public, anon, authenticated;

grant execute on function public.procesar_pago_mercado_pago_webhook(
  uuid, uuid, text, text, numeric, text, boolean, timestamptz, jsonb
) to service_role;
