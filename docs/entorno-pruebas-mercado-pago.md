# Entorno de pruebas de Mercado Pago

## Estado
- Rama: `auditoria-mercado-pago`.
- No se creó una rama nueva de Supabase ni otro proyecto: la única rama listada por la cuenta es `main`, cuyo identificador apunta al proyecto de producción.
- No se aplicó la migración del webhook ni se desplegó la Edge Function.
- No se usaron pedidos, comercios, tokens ni pagos reales para las pruebas automatizadas.

## Pruebas agregadas al repositorio
El workflow `.github/workflows/prueba-webhook-mercado-pago.yml` prepara un PostgreSQL 17 descartable dentro de GitHub Actions y ejecuta:
1. Creación de un esquema ficticio con las tablas mínimas de pedidos, pagos y comisiones.
2. Aplicación de la migración del webhook únicamente en esa base descartable.
3. Pruebas de aprobación, cálculo y cobro de comisión del 5%, notificación repetida, notificación tardía, importe incorrecto, comisión faltante, autorización no capturada, mediación, reutilización de ID de pago, reembolso e idempotencia.
4. Verificación estática de TypeScript de la Edge Function con Deno.

El workflow no necesita credenciales de Mercado Pago ni de Supabase y no se conecta a producción.

## Límites actuales
- Estas pruebas validan la lógica SQL y los tipos/imports del código, no el recorrido real de OAuth ni el Checkout Pro de Mercado Pago.
- Falta ejecutar el workflow y corregir cualquier error que detecte.
- Falta probar las notificaciones reales de sandbox y la firma HMAC con el contrato exacto de la aplicación.
- Falta resolver el bloqueo/serialización de renovación de refresh token para evitar carreras entre notificaciones simultáneas.
- La ruta actual del borrador de función es `supabase/edge-functions/mp-payment-webhook`; antes de desplegar hay que integrarla con la estructura real de Edge Functions de este repositorio/proyecto.
- Los contracargos y reembolsos parciales necesitan una regla contable/operativa acordada antes de producción.

## Regla de seguridad
No desplegar, aplicar migraciones ni cambiar secretos de producción hasta completar las pruebas, revisar el resultado y obtener autorización expresa.
