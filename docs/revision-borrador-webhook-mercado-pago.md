# Revisión del borrador — webhook Mercado Pago

Estado: preparado en la rama `auditoria-mercado-pago`; NO desplegado y NO aplicado a la base de datos.

## Archivos nuevos
- `supabase/edge-functions/mp-payment-webhook/index.ts`: borrador de webhook que verifica HMAC, consulta el pago directamente a Mercado Pago, valida vendedor/comercio/importe/moneda y modo test/live, renueva token próximo a vencer y delega las escrituras a una RPC.
- `supabase/migrations/20261118_mp_webhook_atomic.sql`: borrador de RPC transaccional para registrar pago y actualizar pedido/comisión dentro de la misma transacción.

## Validaciones de esquema ya cotejadas
- Estados válidos de pago: pendiente, aprobado, rechazado, cancelado, reembolsado, reembolso_parcial y en_disputa.
- Estados válidos de comisión: pendiente, devengada, cobrada, liquidada y revertida.
- Estados válidos de pedido: pendiente, confirmado, preparando, listo, enviado, completado, cancelado y reembolsado.
- Existe unicidad para `pagos.idempotencia`, para `(proveedor, referencia_externa)` y para `comisiones.pedido_id`.
- La comisión se almacena como importe de la comisión de plataforma, calculado al crear el pedido.

## Pendientes antes de aceptar el código
1. Ejecutar la migración en un proyecto de desarrollo aislado y validar sintaxis/permisos; no se aplicó en producción.
2. Probar la RPC con pagos de prueba y verificar reintentos, duplicados y cambios de estado.
3. La rama ahora incluye un bloqueo con lease por comercio (`mercado_pago_refresh_locks`) y la función vuelve a leer los tokens después de adquirirlo. También espera el token renovado si otra notificación ganó la carrera. Esta protección tiene pruebas SQL automatizadas; falta que pase el nuevo workflow y validarla contra OAuth Sandbox real.
4. Confirmar el contrato real de las notificaciones (especialmente presencia de `user_id` y firma) usando notificaciones de prueba de la aplicación.
5. Confirmar que la cuenta marketplace recibe el marketplace fee esperado y cómo se concilia con comisiones, reembolsos parciales y contracargos.

## Importante
El borrador no debe desplegarse todavía. La renovación de token debe quedar protegida contra concurrencia y las pruebas de sandbox deben pasar antes de integrar esta versión.


## Nueva protección de concurrencia (borrador)
- Migración: `supabase/migrations/20261118_mp_token_refresh_lock.sql`.
- Pruebas: `supabase/tests/mercado-pago/verificar-bloqueo-refresh.sql`.
- El bloqueo se concede a un solo proceso por comercio y vence automáticamente a los 45 segundos (el servidor limita el lease entre 15 y 120 segundos).
- Solo `service_role` puede ejecutar las funciones de bloqueo; la tabla tiene RLS habilitado y no tiene políticas para clientes.
- El guardado del token renovado usa comparación del refresh token anterior para evitar sobrescribir una rotación más reciente.
- La función no registra tokens ni payloads sensibles en logs.

La nueva protección no se considera aprobada hasta que GitHub Actions complete ambas pruebas y se valide la renovación con cuentas de prueba de Mercado Pago.
