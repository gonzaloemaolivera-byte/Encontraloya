# Cómo habilitar la consulta de estado de pedidos y el panel de Mercado Pago

Todo el código ya está en este repositorio y probado. Falta activar tres
funciones nuevas en Supabase y aplicar una migración SQL. Son pasos que solo
el administrador puede hacer porque requieren los accesos del proyecto.

Se puede hacer todo desde un iPhone con el navegador (Safari o Chrome).

> Nota: los dos workflows de GitHub (publicación automática y pruebas CI) se
> activan copiando su contenido desde `docs/github-workflows/` a
> `.github/workflows/` desde la web de GitHub, porque la App de GitHub de
> Netlify no tiene permiso para publicar esa carpeta (ver paso 2, Opción A).

---

## Paso 1 — Aplicar la migración SQL (una sola vez)

1. Entrar a **https://supabase.com/dashboard** y abrir el proyecto
   `egvchkzktjaitskcqlnr` (Encontralo Ya).
2. Menú lateral: **SQL Editor** → **New query**.
3. Copiar TODO el contenido del archivo
   [`supabase/migrations/20261115160000_estado_pedido_y_oauth_status.sql`](../supabase/migrations/20261115160000_estado_pedido_y_oauth_status.sql)
   de este repositorio (abrirlo en GitHub, tocar "Raw", copiar todo) y pegarlo
   en el editor.
4. Botón **Run**. Debe decir "Success. No rows returned" (o similar).
5. Para verificar que quedó aplicada, pegar y ejecutar:
   ```sql
   SELECT public.obtener_comision_plataforma();
   ```
   Debe devolver `0.05` (la comisión actual de 5%).

### Cambiar la comisión en el futuro

En el mismo SQL Editor:
```sql
SELECT public.establecer_comision_plataforma(0.07);  -- ejemplo: 7%
```
Todo el sistema la lee de ahí; no hay que reprogramar nada. El valor se
escribe como proporción: `0.05` = 5%, `0.10` = 10%.

---

## Paso 2 — Publicar las 3 funciones nuevas en Supabase

Opción A (recomendada, automática para siempre):

1. Entrar a **https://supabase.com/dashboard** → icono de la cuenta (esquina
   inferior izquierda) → **Access Tokens** → **Generate new token**.
2. Copiar el token que empieza con `sbp_`.
3. Abrir **https://github.com/gonzaloemaolivera-byte/Encontraloya**
   → **Settings** → **Secrets and variables** → **Actions** →
   **New repository secret**:
   - Nombre: `SUPABASE_ACCESS_TOKEN` — Valor: el token copiado.
   - Crear otro secreto: nombre `SUPABASE_PROJECT_ID`, valor
     `egvchkzktjaitskcqlnr`.
4. Activar el workflow de publicación (una sola vez): en el repositorio de
   GitHub → **Add file** → **Create new file** → ruta
   `.github/workflows/deploy-supabase-functions.yml` → pegar el contenido de
   [`docs/github-workflows/deploy-supabase-functions.yml`](../docs/github-workflows/deploy-supabase-functions.yml)
   → Commit.
5. A partir de ahí, cada vez que este repositorio publique cambios en
   `supabase/functions/**`, GitHub publica las funciones solo.

Opción B (manual, desde el celular):

1. En el panel de Supabase: **Edge Functions** → **Create a new function** →
   **Start from a blank template** → nombre exacto: `estado-pedido`.
2. Reemplazar el código del template por el contenido de
   [`supabase/functions/estado-pedido/index.ts`](../supabase/functions/estado-pedido/index.ts)
   y tocar **Deploy**.
3. En la configuración de `estado-pedido`, desactivar **Verify JWT / Verificar JWT**.
   Esta función es pública para compradores: valida un código de seguimiento
   aleatorio de 256 bits y su hash privado en la base de datos. No debe exigir
   una sesión de usuario.
4. Repetir con `mp-oauth-status`
   ([código](../supabase/functions/mp-oauth-status/index.ts)) y
   `mp-oauth-disconnect`
   ([código](../supabase/functions/mp-oauth-disconnect/index.ts)). En estas dos
   funciones dejar **Verify JWT / Verificar JWT activado**, porque requieren
   la sesión del titular del comercio.

> Importante: la opción B no reemplaza las funciones ya desplegadas
> (crear-pedido, mp-create-preference, mp-oauth-start, mp-oauth-callback,
> mp-payment-webhook): esas siguen funcionando como están.

---

## Paso 3 — Verificar que todo quedó activo

Desde el navegador del teléfono (o una computadora), ejecutar:

```bash
curl -s -X POST https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/estado-pedido \
  -H "Content-Type: application/json" \
  -d '{"pedido_id":"00000000-0000-0000-0000-000000000000","checkout_token":"0000000000000000000000000000000000000000000000000000000000000000"}'
```

Resultado esperado: `{"ok":false,"mensaje":"No encontramos el pedido."}`
Si responde eso, la función quedó publicada y activa. La llamada debe poder
llegar al código sin un JWT de usuario; la protección del pedido es el token
aleatorio de seguimiento, que nunca se devuelve desde la base de datos.

---

## Paso 4 — Revisión de secretos (una sola vez, ya casi listo)

En **Supabase → Edge Functions → Secrets** verificar que estén cargados:

| Variable | Para qué se usa |
|---|---|
| `MP_CLIENT_ID` y `MP_CLIENT_SECRET` | Conexión OAuth de cada comercio |
| `MP_REDIRECT_URI` | `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback` |
| `MP_WEBHOOK_SECRET` | Validar la firma de las notificaciones de Mercado Pago |
| `MP_TOKEN_ENCRYPTION_KEY` | Cifrar los tokens de las cuentas vinculadas |
| `SITE_URL` | `https://genuine-nasturtium-f4db10.netlify.app` |

Si `MP_WEBHOOK_SECRET` falta, el webhook seguirá rechazando todas las
notificaciones de Mercado Pago (correcto por seguridad, pero el pago nunca
se confirmaría). El valor se obtiene de la aplicación de Mercado Pago
(**Mercado Pago Developers → Tu aplicación → Webhooks → clave de firma**).

---

## Paso 5 — Configuración de la aplicación de Mercado Pago

En **https://developers.mercadopago.com** → Tu aplicación:

1. **Redirect URI (OAuth):**
   `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-oauth-callback`
2. **Webhooks / Notificaciones:**
   URL `https://egvchkzktjaitskcqlnr.supabase.co/functions/v1/mp-payment-webhook`
   con el evento `payment`.

---

## Probar el circuito completo (sin dinero real)

1. Crear una cuenta nueva de prueba de Mercado Pago (vendedor) y otra de
   comprador en Mercado Pago Developers → **Test accounts**.
2. En el panel del comercio de prueba: **Conectar Mercado Pago** → autorizar
   con la cuenta de prueba vendedora.
3. Comprar un producto barato desde la página principal con la cuenta
   compradora de prueba.
4. Al volver del checkout, la página muestra el estado real del pago
   (aprobado / pendiente / rechazado) consultando al servidor, no a la
   respuesta de Mercado Pago.

---

## Volver a producción

Cuando las pruebas con cuentas de prueba estén completas:

1. Confirmar que la aplicación de Mercado Pago esté aprobada en modo
   producción y que los comercios conectados usen cuentas reales.
2. No hay que cambiar nada de código: el mismo circuito funciona en
   producción; solo dejan de usarse las cuentas de prueba.
