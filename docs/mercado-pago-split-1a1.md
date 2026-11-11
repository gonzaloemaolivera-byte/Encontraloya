# Integración Mercado Pago — Encontralo Ya

## Objetivo

Integrar **Split de Pagos 1:1 con Checkout Pro (Preferences API)** para que cada comercio vendedor autorice a Encontralo Ya mediante OAuth y Mercado Pago distribuya el pago entre el vendedor y el marketplace.

La comisión propia de Encontralo Ya se mantiene en el 5%, configurable desde la base de datos. No confundirla con `marketplace_fee`, que es el importe que se cobra a favor del marketplace en Mercado Pago.

## Estado y seguridad

- La aplicación existente de Mercado Pago fue creada con Checkout Pro y actualmente figura con API de Orders.
- La documentación oficial de Mercado Pago indica que, en la edición de una aplicación Checkout Pro, se puede cambiar la API integrada entre Orders y Preferences.
- La documentación Split 1:1 exige elegir el modelo Marketplace. La pantalla de edición permite seleccionar modelos de integración cuando el producto lo admite; todavía falta comprobar si Marketplace aparece para esta aplicación ya creada.
- El trabajo de integración se mantiene en la rama `integracion-mercado-pago`. No mezclar con `main`, no desplegar las Edge Functions y no publicar cambios de Netlify hasta terminar las verificaciones.
- No se habilitaron cobros reales ni se completó una prueba de punta a punta.
- La rama de integración y `main` están divergidas; cualquier integración de cambios debe revisarse cuidadosamente y no hacerse a ciegas.

## Configuración que debe verificarse en Mercado Pago

1. Abrir la aplicación existente **Encontralo Ya** desde Tus integraciones.
2. Entrar en **Editar aplicación**.
3. Confirmar que el producto siga siendo **Checkout Pro**.
4. En el campo de API integrada, seleccionar **Preferences** (no Orders).
5. Comprobar si aparece el modelo **Marketplace** y seleccionarlo si está disponible.
6. Configurar la Redirect URL de OAuth exactamente como se indica abajo.
7. Guardar únicamente después de comprobar los valores. No eliminar ni duplicar la aplicación.

Si Marketplace no aparece en la edición, no crear otra aplicación todavía: consultar a soporte de Mercado Pago si el modelo puede habilitarse en la aplicación existente y qué procedimiento corresponde.

### Redirect URL OAuth

`https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback`

Debe ser una URL HTTPS estática y coincidir exactamente con la usada en OAuth.

### Webhook de prueba

- URL: `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-payment-webhook`
- Entorno: **Prueba**.
- Evento: **payment** (no Order), porque el flujo implementado usa Preferences API.
- Guardar la firma secreta directamente como secreto de Supabase `MP_WEBHOOK_SECRET`. Nunca pegarla en GitHub ni en el chat.

## Secretos requeridos en Supabase Edge Functions

Configurar en Supabase Dashboard → Edge Functions → Secrets:

- `MP_CLIENT_ID`: ID de aplicación (APP_ID).
- `MP_CLIENT_SECRET`: SECRET_KEY de la aplicación.
- `MP_REDIRECT_URI`: `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback`.
- `MP_TOKEN_ENCRYPTION_KEY`: clave aleatoria de 32 bytes codificada en Base64URL.
- `MP_WEBHOOK_SECRET`: firma secreta del webhook del entorno Prueba.
- `SITE_URL`: `https://genuine-nasturtium-f4db10.netlify.app`.

Supabase provee `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` a las Edge Functions. La clave `service_role` nunca debe ir al frontend ni a GitHub. No compartir Client Secret, Access Tokens, Refresh Tokens, claves de cifrado ni firma secreta.

## Flujo técnico implementado en la rama de integración

1. El comerciante inicia sesión en el panel y elige el comercio que administra.
2. `mp-oauth-start` valida la sesión y la propiedad del comercio; crea un `state` aleatorio de un solo uso con vencimiento.
3. El comerciante autoriza a Encontralo Ya en Mercado Pago.
4. `mp-oauth-callback` consume el `state`, intercambia el código OAuth y cifra los tokens con AES-GCM antes de guardarlos en tablas privadas.
5. `mp-create-preference` valida el pedido pendiente, obtiene o renueva el token OAuth del vendedor y llama a `POST https://api.mercadopago.com/checkout/preferences` con los ítems, importes, referencia externa, URLs de retorno y `marketplace_fee`. Devuelve la URL de checkout de prueba o producción según el modo de las credenciales.
6. Mercado Pago notifica eventos `payment`. `mp-payment-webhook` valida la firma HMAC, consulta el pago en `GET /v1/payments/{id}` usando el token del vendedor y verifica vendedor, moneda, importe y referencia antes de actualizar pagos, pedidos y comisiones.

## Reglas del marketplace

- Split 1:1 requiere que cada comercio vendedor autorice OAuth. Nunca reutilizar el token de un vendedor para otro.
- Checkout Pro Split 1:1 documenta `marketplace_fee` en la creación de preferencias mediante `POST /checkout/preferences`.
- La comisión de Mercado Pago se descuenta según las condiciones de la plataforma; la comisión de Encontralo Ya se calcula por separado desde la tabla `comisiones`, actualmente con un 5% esperado y configurable.
- No confiar en las URLs de retorno para confirmar pagos. La confirmación se realiza mediante consulta autenticada del pago y webhook firmado.
- No asumir que un pedido quedó pagado solo porque el comprador regresó a la web.

## Pruebas pendientes antes de desplegar

1. Confirmar en la aplicación de Mercado Pago Checkout Pro + API Preferences y el modelo Marketplace.
2. Configurar Redirect URL y secretos de prueba en Supabase.
3. Configurar Webhook de prueba para el evento `payment`.
4. Desplegar las funciones de la rama de integración en un entorno de prueba controlado, después de revisar los secretos y la configuración.
5. Vincular una cuenta de vendedor de prueba mediante OAuth.
6. Crear un pedido de prueba y comprobar que se genera una preferencia y se abre el checkout sandbox.
7. Probar pagos aprobados, pendientes, rechazados/cancelados y reembolsos; verificar el reparto real de `marketplace_fee`.
8. Revisar idempotencia, permisos, registros, reintentos y que los webhooks atrasados no degraden estados finales.
9. Solo después de superar las pruebas, preparar un despliegue controlado y, más adelante, habilitar producción.

## Referencias oficiales

- [Crear configuración de Split 1:1](https://www.mercadopago.com.ar/developers/es/docs/split-payments/split-1-1/integration-configuration/create-configuration)
- [Integrar checkout en Split de Pagos 1:1](https://www.mercadopago.com.ar/developers/es/docs/split-payments/split-1-1/integration-configuration/integrate-marketplace)
- [Datos de integración de Checkout Pro Preferences](https://www.mercadopago.com.ar/developers/es/docs/checkout-pro-preferences/additional-content/your-integrations/application-details)
