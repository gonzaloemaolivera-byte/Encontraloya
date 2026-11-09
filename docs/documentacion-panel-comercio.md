# Panel del comercio — Documentación para revisión

**Estado: borrador para revisión. Nada de esto se ejecutó en Supabase ni se
publicó en producción.** El merge del Pull Request queda pendiente de la
autorización de Gonzalo.

## Qué cambia

Se incorpora un acceso privado para comercios con las siguientes piezas:

| Archivo | Qué es | Qué incorpora |
|---|---|---|
| `panel-comercio.html` (nuevo) | Página privada para comercios | Inicio de sesión con **Supabase Auth (correo y contraseña)**, reclamo del comercio con código privado y publicación/edición de productos propios. Usa la misma paleta azul (`#102a43`, `#1769aa`) y verde (`#16845b`) del sitio. |
| `index.html` (3 líneas) | Sitio público | Solo agrega el enlace **"Panel del comercio"** en el encabezado. El catálogo, la búsqueda y el formulario de registro quedan intactos, con el mismo diseño. |
| `supabase/migracion-comercial-para-revision.sql` (nuevo) | Migración SQL **solo para revisión** | Usa la columna existente `propietario_id` en `comercios`, un índice no único para permitir varios comercios por cuenta y funciones `SECURITY DEFINER` para reclamar y administrar productos. No modifica permisos de borrado. |
| `docs/documentacion-panel-comercio.md` (nuevo) | Este documento | Explicación de cambios, permisos y procedimiento de aplicación. |

## Cómo funciona el acceso privado

1. El comerciante entra a `panel-comercio.html` y crea una cuenta o inicia
   sesión con **correo y contraseña** (Supabase Auth).
2. Si su usuario aún no tiene comercio vinculado, el panel le muestra la
   lista de comercios **sin titular** (función `comercios_sin_reclamar()`,
   que devuelve solo nombre y localidad) y le pide el **código privado**
   que le fue entregado.
3. Al reclamar, se ejecuta `reclamar_comercio()`, una función
   **SECURITY DEFINER** que compara el código contra la columna
   `codigo_vendedor` **dentro de la base de datos**. El código nunca viaja
   al navegador ni se puede leer por la API pública.
4. Un único `UPDATE` con las condiciones `propietario_id IS NULL` y el código
   correcto hace el reclamo atómico: cada comercio solo puede vincularse una
   vez. Una misma cuenta puede administrar varios comercios.

> El teléfono **no** se usa como prueba de titularidad. La única vía para
> vincular un comercio a un usuario es el código privado validado en el
> servidor.

## Permisos y seguridad

**Columna `codigo_vendedor` (protección respetada):** hoy la lectura
pública de `comercios` usa permisos por columna y `codigo_vendedor` no está
incluido — se verificó contra el proyecto real: pedir `*` o esa columna
devuelve `permission denied`. La migración agrega un
`REVOKE SELECT (codigo_vendedor)` explícito para blindarlo frente a futuros
`GRANT SELECT ON ALL TABLES` accidentales.

**Administración de productos:** el panel no usa la API REST para escribir:
usa las funciones `crear_producto()` y `actualizar_producto()`, que
verifican que el producto o comercio pertenezca a alguno de los comercios
vinculados al usuario autenticado (`propietario_id = auth.uid()`). Una
cuenta puede administrar varios comercios, pero no alcanza los productos
de comercios ajenos.

**Sin borrados:**

* El panel no tiene botón de borrado y no existe función de borrado. Un
  producto que ya no se ofrece simplemente se marca como "no disponible".
* En una prueba, un `DELETE` sobre un identificador inexistente devolvió
  HTTP 204. Eso **no demuestra** que el rol `anon` pueda borrar filas
  existentes: PostgREST también puede devolver 204 cuando la consulta no
  encuentra filas. Por ese motivo, esta migración no modifica permisos
  `DELETE` ni afirma haber demostrado ese permiso.
* Se restringe `EXECUTE` de todas las funciones nuevas al rol
  `authenticated` (`anon` y `PUBLIC` quedan revocados).

**Compatibilidad con lo que ya existe:** la migración no ejecuta ni un
`UPDATE` ni un `DELETE` sobre filas existentes, no habilita RLS y no cambia
los permisos actuales del catálogo público ni del formulario de registro.
Agrega un índice no único sobre `propietario_id` y cinco funciones. No agrega columnas, no cambia políticas RLS y no modifica permisos de borrado.

## Cómo aplicar la migración de forma segura (cuando sea autorizada)

1. **No ejecutar en producción directamente.** Probar primero en un
   proyecto de Supabase de prueba (o un branch de base de datos) con una
   copia de los datos.
2. Hacer un **respaldo** previo: en el dashboard, *Database → Backups*, o
   con `pg_dump` desde una conexión directa.
3. Ejecutar el script completo desde el **SQL Editor** del proyecto. Está
   envuelto en `BEGIN/COMMIT`: si alguna línea falla, la transacción se
   revierte completa y la base queda como estaba.
4. Verificar después:
   - `SELECT propietario_id, count(*) FROM public.comercios GROUP BY 1;` → los
     comercios existentes deben conservar sus valores actuales; la migración
     no los asigna ni los modifica.
   - El catálogo público (`index.html`) debe seguir cargando los 4
     productos actuales.
   - Intentar `DELETE` de un producto con la clave publicable debe
     fallar con permiso denegado.
5. Recién después del deploy del panel, entregar los códigos privados a
   cada titular por un canal directo (nunca por la web pública).

## Qué NO incluye este cambio

* No se ejecutó SQL en Supabase: la migración está preparada **solo para
  revisión**.
* La cuenta puede vincular varios comercios; cada comercio conserva un
  único `propietario_id`.
* No se tocó la base de datos existente ni se modificó o eliminó ningún
  comercio, producto o dato.
* No se integró el PR a `main`: queda abierto para la revisión conjunta.
