// Consola de usuarios · Inventario y Trazabilidad (Clear Petroleum)
// Crea cuentas con usuario y contraseña, habilita/deshabilita, cambia rol y permisos,
// y restablece contraseñas. Solo para perfiles con el permiso "usuarios".
import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DOMINIO = "usuarios.inventario-clear.app"; // correo interno: nadie recibe mails
const ROLES = ["Administrador", "Supervisor", "Operador", "Consulta"];
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const err = (mensaje: string, status = 400) => json({ error: mensaje }, status);
const admin = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

const normUsuario = (u: unknown) => String(u ?? "").trim().toLowerCase();
const validarUsuario = (u: string) => /^[a-z0-9._-]{3,40}$/.test(u);
const validarClave = (c: unknown) => typeof c === "string" && c.length >= 8 && /[A-Za-z]/.test(c) && /[0-9]/.test(c);
const MSG_CLAVE = "La contraseña debe tener al menos 8 caracteres, con letras y números.";

async function auditar(actor: { id: string | null; nombre: string }, perfil: { id?: string; usuario?: string }, accion: string, detalle: string) {
  await admin.from("auditoria_usuarios").insert({ actor_id: actor.id, actor_nombre: actor.nombre, perfil_id: perfil.id ?? null, perfil_usuario: perfil.usuario ?? null, accion, detalle });
}
async function permisosValidos(lista: unknown): Promise<string[]> {
  if (!Array.isArray(lista)) return [];
  const { data } = await admin.from("permisos").select("clave");
  const ok = new Set((data ?? []).map((p) => p.clave));
  return [...new Set(lista.map(String))].filter((p) => ok.has(p));
}
async function fijarPermisos(perfilId: string, lista: string[]) {
  await admin.from("perfil_permisos").delete().eq("perfil_id", perfilId);
  if (lista.length) await admin.from("perfil_permisos").insert(lista.map((permiso) => ({ perfil_id: perfilId, permiso })));
}
async function adminsActivos(): Promise<number> {
  const { count } = await admin.from("perfiles").select("id", { count: "exact", head: true }).eq("rol", "Administrador").eq("activo", true);
  return count ?? 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return err("Método no permitido", 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return err("Solicitud inválida"); }
  const accion = String(body.accion ?? "");

  // ---- Primer administrador: solo si todavía no existe ningún usuario ----
  if (accion === "inicializar") {
    const { count } = await admin.from("perfiles").select("id", { count: "exact", head: true });
    if ((count ?? 0) > 0) return err("El sistema ya tiene usuarios. Pedí el alta a un administrador.", 403);
    const usuario = normUsuario(body.usuario), nombre = String(body.nombre ?? "").trim();
    if (!validarUsuario(usuario) || !nombre) return err("Usuario o nombre inválido");
    if (!validarClave(body.clave)) return err(MSG_CLAVE);
    const { data, error } = await admin.auth.admin.createUser({ email: `${usuario}@${DOMINIO}`, password: String(body.clave), email_confirm: true, user_metadata: { usuario, nombre } });
    if (error || !data.user) return err(error?.message ?? "No se pudo crear el usuario");
    const { error: e2 } = await admin.from("perfiles").insert({ id: data.user.id, usuario, nombre, rol: "Administrador", debe_cambiar_clave: true });
    if (e2) { await admin.auth.admin.deleteUser(data.user.id); return err(e2.message); }
    await auditar({ id: data.user.id, nombre: "Sistema" }, { id: data.user.id, usuario }, "Inicialización", `Primer administrador: ${nombre}`);
    return json({ ok: true, id: data.user.id });
  }

  // ---- Resto de las acciones: requiere un usuario con permiso "usuarios" ----
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: quien } = await admin.auth.getUser(token);
  if (!quien?.user) return err("Sesión inválida", 401);
  const { data: yo } = await admin.from("perfiles").select("id, usuario, nombre, rol, activo").eq("id", quien.user.id).maybeSingle();
  if (!yo || !yo.activo) return err("Usuario sin acceso", 403);
  const { data: misPerm } = await admin.from("perfil_permisos").select("permiso").eq("perfil_id", yo.id);
  const soyAdmin = yo.rol === "Administrador";
  if (!soyAdmin && !(misPerm ?? []).some((p) => p.permiso === "usuarios")) return err("Tu usuario no tiene el permiso para administrar usuarios", 403);
  const actor = { id: yo.id, nombre: yo.nombre };

  if (accion === "crear") {
    const usuario = normUsuario(body.usuario), nombre = String(body.nombre ?? "").trim(), rol = String(body.rol ?? "");
    if (!validarUsuario(usuario)) return err("El usuario debe tener entre 3 y 40 caracteres: letras minúsculas, números, punto, guion o guion bajo.");
    if (!nombre) return err("El nombre es obligatorio");
    if (!ROLES.includes(rol)) return err("Perfil inválido");
    if (rol === "Administrador" && !soyAdmin) return err("Solo un Administrador puede crear otro Administrador", 403);
    if (!validarClave(body.clave)) return err(MSG_CLAVE);
    const { data: existe } = await admin.from("perfiles").select("id").eq("usuario", usuario).maybeSingle();
    if (existe) return err("Ese usuario ya existe");
    let perms = await permisosValidos(body.permisos);
    if (!soyAdmin) perms = perms.filter((p) => p !== "usuarios");
    const { data, error } = await admin.auth.admin.createUser({ email: `${usuario}@${DOMINIO}`, password: String(body.clave), email_confirm: true, user_metadata: { usuario, nombre } });
    if (error || !data.user) return err(error?.message?.includes("already") ? "Ese usuario ya existe" : (error?.message ?? "No se pudo crear el usuario"));
    const { error: e2 } = await admin.from("perfiles").insert({ id: data.user.id, usuario, nombre, rol, creado_por: yo.id, debe_cambiar_clave: true });
    if (e2) { await admin.auth.admin.deleteUser(data.user.id); return err(e2.message); }
    await fijarPermisos(data.user.id, rol === "Administrador" ? [] : perms);
    await auditar(actor, { id: data.user.id, usuario }, "Alta de usuario", `${nombre} · ${rol}${perms.length ? " · permisos: " + perms.join(", ") : ""}`);
    return json({ ok: true, id: data.user.id });
  }

  const id = String(body.id ?? "");
  const { data: obj } = await admin.from("perfiles").select("id, usuario, nombre, rol, activo").eq("id", id).maybeSingle();
  if (!obj) return err("Usuario inexistente", 404);
  if (obj.rol === "Administrador" && !soyAdmin) return err("Solo un Administrador puede modificar a otro Administrador", 403);

  if (accion === "actualizar") {
    const cambios: string[] = [];
    const upd: Record<string, unknown> = { actualizado_en: new Date().toISOString() };
    if (body.nombre !== undefined && String(body.nombre).trim() && String(body.nombre).trim() !== obj.nombre) { upd.nombre = String(body.nombre).trim(); cambios.push(`nombre: ${obj.nombre} → ${upd.nombre}`); }
    if (body.rol !== undefined && body.rol !== obj.rol) {
      if (!ROLES.includes(String(body.rol))) return err("Perfil inválido");
      if ((body.rol === "Administrador" || obj.rol === "Administrador") && !soyAdmin) return err("Solo un Administrador puede asignar o quitar el perfil Administrador", 403);
      if (obj.id === yo.id) return err("No podés cambiar tu propio perfil");
      if (obj.rol === "Administrador" && obj.activo && (await adminsActivos()) <= 1) return err("Debe quedar al menos un Administrador activo");
      upd.rol = body.rol; cambios.push(`perfil: ${obj.rol} → ${body.rol}`);
    }
    if (body.activo !== undefined && Boolean(body.activo) !== obj.activo) {
      if (obj.id === yo.id) return err("No podés deshabilitar tu propio usuario");
      if (!body.activo && obj.rol === "Administrador" && (await adminsActivos()) <= 1) return err("Debe quedar al menos un Administrador activo");
      upd.activo = Boolean(body.activo); cambios.push(body.activo ? "habilitado" : "deshabilitado");
      const { error } = await admin.auth.admin.updateUserById(obj.id, { ban_duration: body.activo ? "none" : "876000h" });
      if (error) return err(error.message);
    }
    const { error } = await admin.from("perfiles").update(upd).eq("id", obj.id);
    if (error) return err(error.message);
    if (body.permisos !== undefined) {
      let perms = await permisosValidos(body.permisos);
      if (!soyAdmin) perms = perms.filter((p) => p !== "usuarios");
      const { data: ant } = await admin.from("perfil_permisos").select("permiso").eq("perfil_id", obj.id);
      const antes = (ant ?? []).map((p) => p.permiso).sort().join(", "), despues = [...perms].sort().join(", ");
      if (antes !== despues) { await fijarPermisos(obj.id, (upd.rol ?? obj.rol) === "Administrador" ? [] : perms); cambios.push(`permisos: [${antes || "ninguno"}] → [${despues || "ninguno"}]`); }
    }
    if (cambios.length) await auditar(actor, obj, "Modificación de usuario", cambios.join(" · "));
    return json({ ok: true, cambios });
  }

  if (accion === "clave") {
    if (!validarClave(body.clave)) return err(MSG_CLAVE);
    const { error } = await admin.auth.admin.updateUserById(obj.id, { password: String(body.clave) });
    if (error) return err(error.message);
    await admin.from("perfiles").update({ debe_cambiar_clave: obj.id !== yo.id, actualizado_en: new Date().toISOString() }).eq("id", obj.id);
    await auditar(actor, obj, "Restablecer contraseña", obj.id === yo.id ? "Cambio de contraseña propia" : "Contraseña temporal asignada: debe cambiarla al ingresar");
    return json({ ok: true });
  }

  return err("Acción desconocida");
});
