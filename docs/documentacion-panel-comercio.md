# Panel del comercio — Documentación para revisión

**Estado: borrador técnico. La migración no se ejecutó en Supabase y el panel no se publicó en producción.** El PR #4 permanece pendiente de revisión y pruebas.

## Qué incorpora

- Acceso con Supabase Auth (correo y contraseña).
- Vinculación de uno o varios comercios por cuenta.
- Publicación y edición de productos propios.
- Funciones SQL `SECURITY DEFINER` con `search_path` vacío y permisos de ejecución limitados a usuarios autenticados.
- Almacenamiento privado de hashes de códigos de titularidad y límites de intentos.

## Seguridad del código de titularidad

1. Cada comercio recibe un token aleatorio de **32 bytes (256 bits)**, representado por 64 caracteres hexadecimales.
2. El token se entrega al titular por un canal directo. No se genera ni se muestra en la web pública.
3. La base almacena únicamente el hash SHA-256 del token en `comercio_codigos_reclamo`; no guarda el token en texto plano.
4. La función `reclamar_comercio()` compara el hash dentro de PostgreSQL, vincula el comercio una sola vez y elimina el hash después del reclamo exitoso.
5. Los intentos incorrectos se limitan a cinco por cuenta y comercio cada 15 minutos, con bloqueo temporal de 30 minutos.
6. El código viaja desde el navegador a Supabase por HTTPS para su validación, pero no se devuelve en la respuesta ni se persiste en el navegador.

La migración invalida todos los códigos preexistentes, porque su entropía no puede demostrarse por su longitud. Cada titular deberá recibir un token nuevo generado criptográficamente. La columna pública antigua se limpia y recibe una restricción CHECK para impedir que vuelva a almacenar texto plano. También limpia `comercios.codigo_vendedor` para que ningún token permanezca en la tabla pública.

**Importante:** el límite se aplica por cuenta y comercio. No reemplaza un control de abuso por IP/WAF, por lo que antes de una apertura masiva conviene agregar monitoreo y protección perimetral.

## Provisionamiento de tokens

El proceso operativo de emisión y entrega todavía debe implementarse. Como procedimiento administrativo temporal:

1. Generar un token con un generador criptográficamente seguro, por ejemplo `openssl rand -hex 32`, en un equipo administrativo confiable.
2. Calcular su SHA-256 localmente y guardar solo los 32 bytes del hash en `public.comercio_codigos_reclamo`.
3. Enviar el token original al titular por un canal directo y confiable.
4. No incluir el token en tickets, logs, repositorios, analítica ni mensajes públicos.

Ejemplo de inserción administrativa (reemplazar los valores localmente; nunca guardar el token en el repositorio):

```sql
INSERT INTO public.comercio_codigos_reclamo (comercio_id, codigo_hash)
VALUES (
  '<UUID-DEL-COMERCIO>'::uuid,
  pg_catalog.decode('<HASH-SHA256-EN-64-CARACTERES-HEX>', 'hex')
);
```

El hash debe calcularse como SHA-256 sobre el token normalizado a minúsculas y codificado en UTF-8; el valor hexadecimal resultante se inserta como 32 bytes con `decode(..., 'hex')`. La restricción única impide reutilizar el mismo token en dos comercios. La inserción debe hacerse con una cuenta administrativa confiable; no se debe conceder este permiso al navegador ni a usuarios autenticados.

## Permisos y datos

- Las tablas privadas de códigos e intentos tienen RLS activado y no conceden permisos a `PUBLIC`, `anon` ni `authenticated`. Las funciones `SECURITY DEFINER` las consultan con privilegios de su propietario.
- `comercios_sin_reclamar()` devuelve solo identificador y datos comerciales básicos; nunca el hash ni el token.
- `datos_del_comercio()` devuelve únicamente los comercios cuyo `propietario_id` coincide con `auth.uid()`.
- `crear_producto()` y `actualizar_producto()` comprueban la titularidad antes de insertar o modificar.
- Una cuenta puede administrar varios comercios; cada comercio conserva un único `propietario_id`.
- No se incorpora una función de borrado ni se cambian permisos DELETE.

## Compatibilidad y efecto de la migración

La migración crea dos tablas privadas, agrega un índice no único sobre `propietario_id`, crea/actualiza cinco funciones y limpia la columna antigua `codigo_vendedor`. No modifica filas de productos ni asigna propietarios a comercios existentes. Sí limpia la columna obsoleta `codigo_vendedor`, invalida tokens débiles y agrega un CHECK que obliga a mantenerla en NULL. Los tokens antiguos que no cumplan el formato nuevo se invalidan.

Antes de ejecutarla se debe confirmar que la versión de PostgreSQL de Supabase soporta las funciones SHA-256 integradas (`pg_catalog.sha256`) y que el usuario que ejecuta la migración puede crear tablas, índices, funciones y cambiar privilegios. No se requiere habilitar extensiones externas.

## Plan de prueba obligatorio

Antes de producción, usar un proyecto Supabase de prueba y comprobar:

1. Un usuario sin sesión no puede ejecutar las funciones privadas.
2. Un usuario autenticado puede ver la lista de comercios pendientes, pero no leer las tablas privadas ni sus hashes.
3. Una clave incorrecta o un ID inexistente no vincula el comercio; cinco intentos incorrectos bloquean temporalmente esa combinación de cuenta y comercio.
4. Una clave válida vincula un comercio una sola vez y queda inutilizable luego del reclamo.
5. Un segundo usuario no puede reclamar un comercio ya vinculado.
6. Un usuario propietario puede crear y editar productos de sus comercios.
7. Otro usuario no puede editar productos ajenos, ni siquiera cambiando IDs manualmente.
8. La lectura pública del catálogo sigue funcionando y no expone `codigo_vendedor`, hashes ni intentos.
9. El formulario público de alta y los cuatro productos actuales permanecen intactos.

También se debe probar expiración y renovación de sesión, errores de red y formularios desde iPhone.

## Fuera de alcance por ahora

- No se ejecutó SQL en Supabase.
- No se modificaron datos reales ni políticas existentes de RLS de las tablas principales.
- No se fusionó el PR ni se desplegó Netlify.
- La emisión y entrega automatizada de tokens, el monitoreo antiabuso por IP y la recuperación de titularidad siguen pendientes.
