# Inventario y Trazabilidad · Clear Petroleum

Aplicación web para el inventario y la trazabilidad de herramientas y equipos. Tiene número de activo permanente (`ACT-000001`), ubicación dinámica, historial que no se puede alterar, fotos, inspecciones, códigos QR, reportes y una consola para administrar usuarios y permisos.

- **Frontend:** sitio estático (`public/`) publicado en Vercel.
- **Backend:** Supabase (PostgreSQL + Auth + Storage + Edge Functions). Proyecto: **Inventario Clear** (`hhwfhearafhmougtfssu`, São Paulo).
- **Manual de usuario:** [`docs/Manual_Usuario_Inventario_Clear.pdf`](docs/Manual_Usuario_Inventario_Clear.pdf)

## Estructura

```
public/                  Sitio que publica Vercel
  index.html             Página
  app.js                 Aplicación
  config.js              URL y clave pública de Supabase
supabase/
  migrations/            Esquema, seguridad (RLS), operaciones y datos iniciales
  functions/admin-usuarios/  Consola de usuarios (Edge Function)
docs/                    Manual de usuario
vercel.json              Configuración de Vercel
```

## Publicar en Vercel (una sola vez)

1. Entrá a <https://vercel.com> e ingresá con tu cuenta de GitHub.
2. **Add New… → Project** y elegí el repositorio **InventacioClear** → **Import**.
3. En *Framework Preset* elegí **Other**. No cambies nada más: `vercel.json` ya indica que el sitio está en `public/`.
4. **Deploy**. En unos segundos vas a tener una dirección del tipo `https://inventacio-clear.vercel.app`.

Cada vez que subas cambios a GitHub, Vercel publica la nueva versión automáticamente.

## Primer ingreso

- Usuario: `chernandez` (Hernandez Claudio, Administrador).
- Contraseña: la temporal que se entregó por privado. El sistema obliga a cambiarla en el primer ingreso.
- Desde **Usuarios** (la consola) se crean las cuentas del resto del equipo. Ahí también se habilitan o deshabilitan personas, se cambian perfiles y permisos (por ejemplo, **Dar de baja activos**) y se asignan contraseñas temporales.

## Ajustes recomendados en Supabase

En el panel de Supabase → proyecto **Inventario Clear**:

1. **Authentication → Sign In / Providers → Email:** desactivá **Allow new users to sign up**. Las cuentas se crean solo desde la consola. Aunque alguien lograra registrarse por su cuenta, sin perfil asignado no ve ni modifica nada.
2. **Authentication → URL Configuration:** en *Site URL* poné la dirección de Vercel.

## Seguridad: cómo está armada

- El navegador solo usa la **clave publicable**. La clave `service_role` vive únicamente dentro de la Edge Function.
- **RLS** en todas las tablas: sin un usuario con perfil habilitado no se puede leer nada.
- Nadie escribe directamente en las tablas. Toda operación (alta, movimiento, baja, etc.) pasa por una función de la base que valida el permiso y registra el historial en la misma transacción.
- **Número de activo:** único (`UNIQUE`), generado por secuencia, bloqueado por trigger ante cualquier `UPDATE` y nunca reutilizado (tabla `numeros_anulados`). Solo cambia con `corregir_numero`, un procedimiento auditado que exige permiso específico.
- El historial, las fotos, las inspecciones, los documentos y la auditoría de usuarios **no se pueden modificar ni borrar**.
- Fotos y documentos en un bucket **privado** (`evidencias`) con enlaces firmados temporales.
- Un usuario deshabilitado queda bloqueado en Auth y en la base, aunque tenga una sesión abierta.

## Permisos

| Permiso | Administrador | Supervisor | Operador | Consulta |
|---|:-:|:-:|:-:|:-:|
| Consultar, reportes, exportar | ✔ | ✔ | ✔ | ✔ |
| Alta y edición de activos | ✔ | ✔ | | |
| Movimientos | ✔ | ✔ | ✔ | |
| Cambio de estado, inspecciones, documentos | ✔ | ✔ | | |
| Fotografías y novedades | ✔ | ✔ | ✔ | |
| Baja y reingreso | ✔ | configurable | configurable | |
| Corrección del número, importar, catálogos | ✔ | configurable | | |
| Administrar usuarios | ✔ | configurable | | |

Los perfiles solo sugieren permisos: desde la consola se ajusta cada permiso por persona.

## Cambios en la base de datos

Las migraciones de `supabase/migrations/` ya están aplicadas en el proyecto. Si hace falta recrearlo desde cero:

```bash
supabase link --project-ref hhwfhearafhmougtfssu
supabase db push
supabase functions deploy admin-usuarios
```
