# Integración Mercado Pago — Split 1:1

## Estado
- Se creó la rama `integracion-mercado-pago`; producción (`main`) no se modificó.
- Se agregó y aplicó la migración de almacenamiento OAuth privado.
- Se desplegaron las Edge Functions `mp-oauth-start` (JWT requerido) y `mp-oauth-callback` (callback público OAuth).
- La interfaz de vinculación está preparada en `panel-comercio.html` dentro de esta rama.
- No se habilitaron cobros ni se guardaron credenciales de Mercado Pago todavía.

## Configuración de la aplicación en Mercado Pago
Crear una aplicación con:
- Solución: Pagos online.
- Producto: Checkout Pro.
- Modelo: Marketplace (Split de Pagos 1:1).

Configurar exactamente esta URL de redireccionamiento:
`https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback`

La aplicación integradora debe cumplir el requisito KYC nivel 6 indicado por Mercado Pago. Cada comercio vendedor deberá autorizar a Encontralo Ya mediante OAuth.

## Secretos que faltan en Supabase Edge Functions
Configurar desde Supabase Dashboard → Edge Functions → Secrets (no en el frontend ni en GitHub):
- `MP_CLIENT_ID`: APP_ID de la aplicación.
- `MP_CLIENT_SECRET`: SECRET_KEY de la aplicación.
- `MP_REDIRECT_URI`: la URL de callback indicada arriba.
- `MP_TOKEN_ENCRYPTION_KEY`: clave aleatoria de 32 bytes codificada en Base64URL.
- `SITE_URL`: `https://genuine-nasturtium-f4db10.netlify.app`.

Supabase ya proporciona `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` a las Edge Functions. No copiar ni publicar la clave service_role.

## Flujo técnico
1. Un comerciante autenticado inicia la vinculación desde su panel.
2. `mp-oauth-start` valida que sea propietario del comercio, crea un `state` de un solo uso con vencimiento de 10 minutos y redirige a Mercado Pago.
3. Mercado Pago devuelve el código a `mp-oauth-callback`.
4. El callback intercambia el código por credenciales y cifra access_token y refresh_token con AES-GCM antes de guardarlos en una tabla con RLS y acceso exclusivo a service_role.
5. El panel muestra el estado de conexión sin exponer tokens.

## Próximas tareas
- Configurar secretos y probar OAuth con una cuenta de prueba.
- Implementar renovación de refresh_token.
- Crear preferencia Checkout Pro con access_token del comercio y `marketplace_fee` calculado desde `configuracion_plataforma.porcentaje_comision` (actualmente 5%).
- Implementar Webhook firmado, verificación de pago consultando la API y actualización idempotente de `pagos`, `pedidos` y `comisiones`.
- Probar aprobación, rechazo, cancelación y reembolso antes de producción.

## Aclaración de comisiones
Mercado Pago indica que su propia comisión se descuenta primero y la comisión del marketplace después. El importe de `marketplace_fee` debe calcularse como el porcentaje de comisión de Encontralo Ya sobre el importe de la venta; las condiciones económicas y la base final deben validarse en pruebas de la cuenta.
