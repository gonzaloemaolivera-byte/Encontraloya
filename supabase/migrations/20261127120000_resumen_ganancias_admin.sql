-- Panel seguro de ganancias para el administrador de Encontralo Ya.
-- No marca comisiones como cobradas: solo informa importes registrados.
CREATE OR REPLACE FUNCTION public.obtener_resumen_ganancias_admin()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_result jsonb;
BEGIN
  IF v_email <> 'administracionencontraloya@gmail.com' THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'porcentaje_actual', coalesce(
      (SELECT porcentaje_comision FROM public.configuracion_plataforma WHERE id = 1),
      5
    ),
    'total_ventas_registradas', coalesce(sum(c.base_calculo), 0),
    'comision_generada', coalesce(sum(c.importe_comision), 0),
    'comision_acreditada', coalesce(sum(c.importe_cobrado), 0),
    'comision_pendiente', coalesce(sum(
      CASE WHEN c.estado IN ('pendiente', 'devengada')
        THEN greatest(c.importe_comision - c.importe_cobrado, 0)
        ELSE 0 END
    ), 0),
    'operaciones', coalesce((
      SELECT jsonb_agg(x.item ORDER BY x.creado_at DESC)
      FROM (
        SELECT jsonb_build_object(
          'pedido_id', c2.pedido_id,
          'fecha', c2.creado_at,
          'porcentaje', c2.porcentaje,
          'base', c2.base_calculo,
          'comision', c2.importe_comision,
          'estado_comision', c2.estado,
          'importe_acreditado', c2.importe_cobrado,
          'estado_pago', p.estado,
          'fecha_pago', p.fecha_confirmacion
        ) AS item, c2.creado_at
        FROM public.comisiones c2
        LEFT JOIN public.pagos p
          ON p.pedido_id = c2.pedido_id
         AND p.proveedor = 'mercado_pago'
        ORDER BY c2.creado_at DESC
        LIMIT 100
      ) x
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.comisiones c;

  RETURN coalesce(v_result, '{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_resumen_ganancias_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_ganancias_admin() TO authenticated;
