# Encontraloya
Plataforma para conectar compradores con comercio

## Novedades de esta rama (circuito Mercado Pago)

- El comprador puede consultar el estado real de su pedido y pago después de
  volver del checkout de Mercado Pago, con el código de seguimiento del
  pedido (pantalla de estado en la página principal).
- El comercio ve el indicador de conexión de Mercado Pago en su panel y puede
  desconectar o volver a conectar su cuenta de forma segura.
- La comisión de la plataforma (5% actual) es configurable en la base de
  datos: `SELECT public.establecer_comision_plataforma(0.05);`
- Activación y pruebas: ver `docs/activar-estado-pedido-mercadopago.md`.
- Los workflows de GitHub (CI y publicación de funciones) se activan copiando
  su contenido desde `docs/github-workflows/` a `.github/workflows/` desde la
  web de GitHub (la App de Netlify no puede publicar esa carpeta).
