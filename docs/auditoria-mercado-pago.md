# Auditoría técnica — Mercado Pago (18/11/2026)

## Alcance y cuidado de producción
Revisión de las Edge Functions activas y de las RPC relacionadas con pedidos, pagos y comisiones en Supabase. Esta auditoría es de solo lectura: no se modificaron funciones activas, tablas, pedidos, pagos, comisiones ni secretos.

Proyecto Supabase: `egvchkzktjaitskcqlnr`
Sitio: `https://genuine-nasturtium-f4db10.netlify.app`

## Estado observado
- Hay 7 Edge Functions activas relacionadas con pedidos y pagos.
- La comisión de plataforma está parametrizada en la base y el pedido guarda una comisión calculada; la integración de Checkout Pro usa `marketplace_fee`.
- El flujo OAuth por comercio existe: el vendedor autoriza y se guardan tokens cifrados.
- La validación HMAC de notificaciones está implementada.
- En la consulta de estado realizada durante esta auditoría no había comercios vinculados a Mercado Pago ni tokens OAuth guardados. Por eso no se pudo completar una transacción real de punta a punta.
- No se verificaron ni se expusieron secretos de Mercado Pago.

## Hallazgos que deben corregirse antes de habilitar cobros reales

### 1. Renovación de token en el webhook
`mp-create-preference` contempla renovar el access token del vendedor y actualizar los tokens cifrados. En cambio, `mp-payment-webhook` actualmente solo descifra y usa el access token almacenado. Cuando ese token expire, las notificaciones pueden dejar de procesarse aunque exista refresh token. Un webhook de pago debe poder renovar la autorización de forma segura o marcar la conexión para reautorización y permitir reintento.

### 2. Validación del entorno
El webhook guarda `live_mode` del pago recibido, pero no compara explícitamente ese valor con el entorno asociado al token/conexión del vendedor. Debe rechazarse cualquier discrepancia test/live antes de actualizar pagos, pedidos o comisiones.

### 3. Errores al sincronizar pedido y comisión
Después de guardar el pago, el webhook intenta actualizar pedido y comisión, pero no comprueba los errores devueltos por ambas operaciones. Puede responder OK aunque el pedido o la comisión no se hayan actualizado. La solución debe hacer la transición de forma atómica mediante una RPC transaccional o, como mínimo, comprobar cada resultado y devolver error reintentable si queda una parte sin sincronizar.

### 4. Idempotencia y eventos repetidos
Mercado Pago puede reenviar notificaciones. El flujo ya usa una clave de idempotencia por pedido, pero la transición de estado debe ser idempotente y no permitir que un evento viejo o tardío revierta un estado más avanzado. Deben contemplarse approved, rejected, cancelled, refunded y charged_back con reglas explícitas.

### 5. Conciliación del importe y vendedor
El webhook ya comprueba referencia externa, vendedor/cobrador, moneda ARS, comercio del pedido e importe total. Hay que conservar esos controles y sumar la validación de entorno y, cuando la API lo exponga de forma fiable, la conciliación de la comisión real de marketplace.

### 6. Checkout
El endpoint de creación de preferencia está protegido por un token de checkout aleatorio de un solo pedido, guardado como hash y con vencimiento. Mantener ese patrón. Revisar las rutas de retorno y la URL de notificación en pruebas antes de producción.

## Hallazgos de seguridad de base de datos que requieren auditoría separada
Supabase Advisors informó:
- 12 tablas con RLS habilitado y sin políticas explícitas; varias están en esquemas privados o son tablas internas que podrían estar correctamente cerradas, por lo que no se deben agregar políticas públicas automáticamente.
- 11 funciones SECURITY DEFINER ejecutables por anon y/o authenticated. Algunas usan tokens o controles internos; hay que revisar cada función y su contrato antes de revocar permisos o cambiar su modo de seguridad.
- Protección contra contraseñas filtradas deshabilitada en Auth.
- Avisos de rendimiento por índices, políticas RLS repetidas y evaluación de auth.uid() por fila.

No realizar cambios masivos sobre RLS, SECURITY DEFINER ni datos existentes como parte de la corrección de Mercado Pago.

## Secuencia segura de implementación
1. Preparar correcciones de webhook y checkout en esta rama, sin desplegar.
2. Revisar el SQL de transición de pago y comisión para garantizar atomicidad e idempotencia.
3. Preparar pruebas con cuentas de prueba de Mercado Pago y vendedores de prueba.
4. Verificar firmas válidas e inválidas, duplicados, tokens expirados, mismatch de entorno, importes incorrectos, vendedor incorrecto, rechazo, cancelación, devolución y contracargo.
5. Solo después de aprobar las pruebas, desplegar primero en un entorno de prueba y luego solicitar autorización expresa para producción.
6. Realizar una compra real de bajo importe solo cuando el titular de la cuenta lo autorice y las pruebas de sandbox hayan pasado.

## Criterio de aceptación
Un pago solo puede marcarse aprobado cuando Mercado Pago confirma el pago consultado directamente, el vendedor coincide con el comercio del pedido, el importe y moneda coinciden, el entorno coincide, y la actualización de pago, pedido y comisión queda confirmada sin errores. Un webhook no debe confiar únicamente en el cuerpo recibido.
