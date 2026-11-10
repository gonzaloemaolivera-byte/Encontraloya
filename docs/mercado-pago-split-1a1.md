# Integración Mercado Pago — Split 1:1 con Checkout Pro Orders API

## Estado y alcance
- La aplicación de Mercado Pago fue creada por el titular de la cuenta en modo de prueba.
- El código de integración se mantiene en la rama `integracion-mercado-pago`; no modificar ni publicar `main` hasta completar pruebas.
- Se implementó el flujo OAuth para que cada comercio autorice su propia cuenta.
- El checkout del comprador se adapta a Checkout Pro mediante Orders API (`POST /v1/orders`), usando `marketplace_fee`.
- El webhook se adapta al tópico `order` y consulta la order directamente en Mercado Pago antes de actualizar la base de datos.
- No se habilitaron cobros reales. No se deben desplegar los cambios ni activar producción hasta configurar credenciales, Marketplace y probar el flujo completo.

## Configuración de Mercado Pago que falta verificar
La documentación Split 1:1 exige una aplicación con Checkout Pro y el modelo Marketplace. Verificar en los detalles/edición de la aplicación que el modelo Marketplace esté habilitado. La aplicación creada utiliza API de Orders.

Configurar exactamente esta Redirect URL para OAuth:
`https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback`

En Configuración de Webhooks, en el entorno Prueba:
- URL: `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-payment-webhook`
- Evento: **Order (Mercado Pago)**.
- Guardar y copiar la firma secreta directamente a Supabase como `MP_WEBHOOK_SECRET`; nunca pegarla en GitHub ni en el chat.

## Secretos requeridos en Supabase Edge Functions
Configurar desde Supabase Dashboard → Edge Functions → Secrets:
- `MP_CLIENT_ID`: ID de aplicación (APP_ID).
- `MP_CLIENT_SECRET`: SECRET_KEY de la aplicación.
- `MP_REDIRECT_URI`: `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback`.
- `MP_TOKEN_ENCRYPTION_KEY`: clave aleatoria de 32 bytes codificada en Base64URL.
- `MP_WEBHOOK_SECRET`: firma secreta de Webhooks para el entorno Prueba.
- `SITE_URL`: `https://genuine-nasturtium-f4db10.netlify.app`.

Supabase provee `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` a las Edge Functions. La clave `service_role` nunca debe ir al frontend ni a GitHub.

## Flujo técnico
1. Un comerciante inicia sesión en el panel y elige el comercio que administra.
2. `mp-oauth-start` valida JWT y propiedad del comercio; crea un state aleatorio de un solo uso con vencimiento de 10 minutos.
3. El comercio autoriza a Encontralo Ya en Mercado Pago.
4. `mp-oauth-callback` consume el state, intercambia el código OAuth y cifra access_token y refresh_token con AES-GCM antes de guardarlos en tablas privadas con RLS.
5. `mp-create-order` valida el pedido pendiente, obtiene/renueva el token del vendedor, crea una order Checkout Pro con items, total, `external_reference`, `marketplace_fee` y URLs de retorno; persiste el ID y `checkout_url`.
6. Mercado Pago envía Webhooks de tipo `order`. `mp-payment-webhook` valida HMAC, consulta `GET /v1/orders/{id}` con el token del vendedor y solo entonces actualiza pagos, pedidos y comisiones.

## Reglas y límites
- La comisión de Encontralo Ya se calcula desde la tabla `comisiones`; el porcentaje actual esperado es 5% y debe seguir siendo configurable.
- La comisión de Mercado Pago se descuenta primero según sus condiciones; la comisión del marketplace se calcula sobre la base acordada y debe validarse en pruebas.
- Split 1:1 exige que cada comercio vendedor autorice OAuth. No se deben reutilizar tokens de un vendedor para otro.
- La documentación de Checkout Pro Orders indica `marketplace_fee` como parámetro de creación de la order. La documentación general de Split 1:1 describe el campo para Preferences API; por eso hay que confirmar la distribución efectiva con una compra de prueba de Marketplace antes de habilitar producción.
- Las credenciales de prueba y cuentas de prueba son necesarias para la validación. No compartir Client Secret, Access Tokens, Refresh Tokens ni firma secreta.
- No confiar en las URLs de retorno para confirmar pagos: el estado se confirma exclusivamente mediante consulta autenticada de la order y Webhook firmado.

## Pruebas pendientes
1. Configurar secretos de prueba y Redirect URL.
2. Verificar que la aplicación tenga modelo Marketplace.
3. Configurar Webhook de prueba para evento Order (Mercado Pago).
4. Vincular un comercio de prueba mediante OAuth.
5. Crear un pedido de prueba y comprobar `checkout_url`.
6. Probar aprobado, pendiente, cancelado/rechazado y reembolso; comprobar el reparto real del `marketplace_fee`.
7. Revisar idempotencia, permisos, registros y reintentos.
8. Solo después de aprobar todas las pruebas, preparar credenciales productivas y un despliegue controlado.
