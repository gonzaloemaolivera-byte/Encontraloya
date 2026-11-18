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
3. Resolver explícitamente la concurrencia de refresh token: Mercado Pago puede rotar el refresh token; dos notificaciones simultáneas podrían intentar renovarlo a la vez. La versión productiva debe serializar esa renovación o implementar un mecanismo de lease/lock.
4. Confirmar el contrato real de las notificaciones (especialmente presencia de `user_id` y firma) usando notificaciones de prueba de la aplicación.
5. Confirmar que la cuenta marketplace recibe el marketplace fee esperado y cómo se concilia con comisiones, reembolsos parciales y contracargos.

## Importante
El borrador no debe desplegarse todavía. La renovación de token debe quedar protegida contra concurrencia y las pruebas de sandbox deben pasar antes de integrar esta versión.
