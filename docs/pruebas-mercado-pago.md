# Matriz de pruebas — cobros de Encontralo Ya

Estas pruebas deben ejecutarse en sandbox antes de conectar un comercio real. No usar pedidos ni datos de producción para simular pagos.

| Caso | Resultado esperado |
|---|---|
| Pago aprobado y vendedor correcto | Pago aprobado; pedido confirmado; comisión cobrada/devengada según el modelo contable acordado |
| Notificación repetida del mismo pago | Sin duplicar pagos, pedidos ni comisiones |
| Firma HMAC ausente o incorrecta | HTTP 401; ningún dato de negocio cambia |
| ID de pago inexistente en Mercado Pago | Respuesta reintentable; pedido y comisión sin cambios |
| Vendedor/cobrador distinto al comercio del pedido | Rechazo; ningún cambio |
| Importe distinto al total del pedido | Rechazo; ningún cambio |
| Moneda distinta de ARS | Rechazo; ningún cambio |
| Pago de sandbox contra token live (o viceversa) | Rechazo por discrepancia de entorno |
| Access token vencido con refresh token vigente | Renovación segura; consulta del pago y procesamiento correcto |
| Refresh token revocado o inválido | No marcar pago aprobado; indicar reconexión del vendedor |
| Pago rechazado | Registrar rechazo; pedido permanece pendiente o pasa al estado definido por negocio |
| Pago cancelado | Registrar cancelación sin borrar historial |
| Pago reembolsado | Registrar devolución y revertir comisión según regla contable |
| Contracargo | Registrar estado en disputa; no tratarlo como venta final |
| Error al actualizar pedido o comisión | No responder éxito como si todo hubiera quedado sincronizado |
| Pedido cancelado antes de pagar | No crear ni aprobar cobro posterior |
| Preferencia generada dos veces | Reutilizar checkout válido o crear uno nuevo bajo regla idempotente sin duplicar cobros |

## Antes de producción
- [ ] Confirmar credenciales de aplicación y Redirect URI en Mercado Pago Developers.
- [ ] Confirmar webhook URL y secreto de firma configurado en la aplicación.
- [ ] Confirmar que los secretos existen en Supabase Edge Function Secrets, sin copiarlos a GitHub ni al navegador.
- [ ] Vincular una cuenta vendedora de prueba mediante OAuth.
- [ ] Ejecutar todos los casos anteriores.
- [ ] Verificar el saldo del vendedor y el marketplace fee en la operación de prueba.
- [ ] Revisar logs sin mostrar tokens, datos personales ni información sensible.
- [ ] Obtener autorización explícita antes de desplegar cambios a producción.
