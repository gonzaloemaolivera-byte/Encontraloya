create or replace function public.obtener_panel_administracion()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Acceso no autorizado' using errcode = '42501';
  end if;

  select lower(u.email)
    into v_email
    from auth.users u
   where u.id = auth.uid()
     and u.email_confirmed_at is not null;

  if v_email is distinct from 'administracionencontraloya@gmail.com' then
    raise exception 'Acceso reservado a administración' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'comercios_total', (select count(*)::integer from public.comercios),
    'productos_total', (select count(*)::integer from public.productos),
    'productos_disponibles', (select count(*)::integer from public.productos where disponible is true),
    'pedidos_total', (select count(*)::integer from public.pedidos),
    'pedidos_pendientes', (select count(*)::integer from public.pedidos where estado = 'pendiente'),
    'servicios_total', (select count(*)::integer from public.solicitudes_servicio),
    'consultas_total', (select count(*)::integer from public.consultas),
    'pagos_aprobados_total', (select coalesce(sum(importe),0)::numeric(14,2) from public.pagos where estado = 'aprobado'),
    'comisiones_generadas', (select coalesce(sum(importe_comision),0)::numeric(14,2) from public.comisiones where estado not in ('revertida')),
    'comisiones_cobradas', (select coalesce(sum(importe_cobrado),0)::numeric(14,2) from public.comisiones),
    'visitas_total', (select count(*)::integer from private.analytics_visitas),
    'comercios_recientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', c.nombre, 'rubro', c.rubro, 'localidad', c.localidad,
        'provincia', c.provincia, 'fecha', c.created_at
      ) order by c.created_at desc)
      from (select * from public.comercios order by created_at desc limit 8) c
    ), '[]'::jsonb),
    'pedidos_recientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', p.numero_pedido, 'comercio', c.nombre, 'estado', p.estado,
        'total', p.total, 'fecha', p.creado_at
      ) order by p.creado_at desc)
      from (select * from public.pedidos order by creado_at desc limit 8) p
      left join public.comercios c on c.id = p.comercio_id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

revoke all on function public.obtener_panel_administracion() from public, anon;
grant execute on function public.obtener_panel_administracion() to authenticated;
