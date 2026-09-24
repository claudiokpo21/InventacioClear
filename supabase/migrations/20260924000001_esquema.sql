-- =====================================================================
--  INVENTARIO Y TRAZABILIDAD · Clear Petroleum
--  01 · Esquema base
--  Regla crítica: el Número de Activo (ACT-000001) es permanente,
--  inmutable, único, sin datos geográficos y nunca se reutiliza.
--  Unicidad e inmutabilidad garantizadas por la base de datos.
-- =====================================================================

-- ---------- Catálogos geográficos y operativos ----------
create table public.paises      (id serial primary key, nombre text not null unique);
create table public.provincias  (id serial primary key, pais_id int not null references public.paises(id), nombre text not null, unique (pais_id, nombre));
create table public.localidades (id serial primary key, provincia_id int not null references public.provincias(id), nombre text not null, unique (provincia_id, nombre));
create table public.bases       (id serial primary key, localidad_id int not null references public.localidades(id), nombre text not null, unique (localidad_id, nombre));
create table public.sectores    (id serial primary key, nombre text not null unique, orden int not null default 100);
create table public.estados     (id serial primary key, nombre text not null unique, critico boolean not null default false, orden int not null default 100);
create table public.tipos_herramienta   (id serial primary key, nombre text not null unique);
create table public.empresas_inspeccion (id serial primary key, nombre text not null unique);
create table public.configuracion (clave text primary key, valor text not null);

-- ---------- Usuarios y permisos ----------
create table public.permisos (
  clave text primary key,
  descripcion text not null,
  orden int not null default 100
);
create table public.perfiles (
  id uuid primary key references auth.users(id) on delete restrict,
  usuario text not null unique check (usuario ~ '^[a-z0-9._-]{3,40}$'),
  nombre text not null,
  rol text not null check (rol in ('Administrador','Supervisor','Operador','Consulta')),
  activo boolean not null default true,
  debe_cambiar_clave boolean not null default true,
  creado_en timestamptz not null default now(),
  creado_por uuid references public.perfiles(id),
  actualizado_en timestamptz not null default now()
);
create table public.perfil_permisos (
  perfil_id uuid not null references public.perfiles(id) on delete cascade,
  permiso text not null references public.permisos(clave),
  primary key (perfil_id, permiso)
);
-- registro de cambios de usuarios y permisos (inalterable)
create table public.auditoria_usuarios (
  id bigint generated always as identity primary key,
  fecha_hora timestamptz not null default now(),
  actor_id uuid references public.perfiles(id),
  actor_nombre text not null,
  perfil_id uuid references public.perfiles(id),
  perfil_usuario text,
  accion text not null,
  detalle text
);

-- ---------- Número de activo ----------
create sequence public.activo_numero_seq start 1 increment 1 no cycle;
create table public.numeros_anulados (
  numero_activo text primary key check (numero_activo ~ '^ACT-[0-9]{6}$'),
  activo_id uuid not null,
  anulado_en timestamptz not null default now(),
  anulado_por uuid references public.perfiles(id),
  motivo text not null
);
create or replace function public.generar_numero_activo() returns text
language plpgsql set search_path = public as $$
declare n text;
begin
  loop
    n := 'ACT-' || lpad(nextval('public.activo_numero_seq')::text, 6, '0');
    exit when not exists (select 1 from public.numeros_anulados where numero_activo = n)
          and not exists (select 1 from public.activos where numero_activo = n);
  end loop;
  return n;
end $$;

-- ---------- Activos ----------
create table public.activos (
  id              uuid primary key default gen_random_uuid(),
  numero_activo   text not null,
  codigo_anterior text,
  tipo_id         int  not null references public.tipos_herramienta(id),
  marca text, modelo text, numero_serie text, numero_precinto text, medida text,
  empresa_inspeccion_id int references public.empresas_inspeccion(id),
  responsable     text,
  provincia_origen_id int not null references public.provincias(id),
  base_id         int  not null references public.bases(id),
  sector_id       int  not null references public.sectores(id),
  ubicacion_especifica text,
  estado_id       int  not null references public.estados(id),
  dado_de_baja    boolean not null default false,
  foto_principal_id uuid,
  observaciones   text,
  fecha_alta      date not null default current_date,
  creado_por      uuid references public.perfiles(id),
  creado_en       timestamptz not null default now(),
  constraint activos_numero_unico   unique (numero_activo),
  constraint activos_numero_formato check (numero_activo ~ '^ACT-[0-9]{6}$'),
  constraint activos_id_numero      unique (id, numero_activo)
);
create unique index activos_serie_unica on public.activos (numero_serie) where numero_serie is not null and numero_serie <> '';
create index activos_base_idx on public.activos (base_id);
create index activos_estado_idx on public.activos (estado_id);

create or replace function public.activos_asignar_numero() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_setting('inv.migracion', true) is distinct from 'on' then
    new.numero_activo := public.generar_numero_activo();
  end if;
  if exists (select 1 from public.numeros_anulados where numero_activo = new.numero_activo) then
    raise exception 'El número % fue anulado y no puede reutilizarse', new.numero_activo;
  end if;
  return new;
end $$;
create trigger trg_activos_asignar_numero before insert on public.activos
  for each row execute function public.activos_asignar_numero();

create or replace function public.activos_proteger() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.id <> old.id then raise exception 'El ID interno del activo es inmutable'; end if;
  if new.provincia_origen_id <> old.provincia_origen_id then raise exception 'La provincia de origen no puede modificarse'; end if;
  if new.numero_activo <> old.numero_activo and current_setting('inv.correccion_numero', true) is distinct from 'on' then
    raise exception 'El Número de Activo % es permanente e inmutable', old.numero_activo;
  end if;
  return new;
end $$;
create trigger trg_activos_proteger before update on public.activos
  for each row execute function public.activos_proteger();

create or replace function public.no_eliminar() returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception 'Los registros de % no se eliminan ni se modifican: use la operación correspondiente', tg_table_name;
end $$;
create trigger trg_activos_no_eliminar before delete on public.activos
  for each row execute function public.no_eliminar();

-- ---------- Registros vinculados (ID interno + Número de activo) ----------
create table public.fotografias (
  id uuid primary key default gen_random_uuid(),
  activo_id uuid not null, numero_activo text not null,
  tipo text not null check (tipo in ('Estado general','Precinto','Número de serie','Placa','Daño','Inspección','Reparación','Otra')),
  archivo text not null,
  observacion text,
  usuario_id uuid references public.perfiles(id), usuario_nombre text not null,
  tomada_en timestamptz not null default now(),
  foreign key (activo_id, numero_activo) references public.activos (id, numero_activo) on update cascade
);
create table public.inspecciones (
  id uuid primary key default gen_random_uuid(),
  activo_id uuid not null, numero_activo text not null,
  empresa_inspeccion_id int references public.empresas_inspeccion(id),
  fecha date not null, fecha_vencimiento date not null check (fecha_vencimiento >= fecha),
  resultado text not null check (resultado in ('Aprobada','Aprobada con observaciones','Rechazada')),
  numero_certificado text, observaciones text,
  usuario_id uuid references public.perfiles(id), usuario_nombre text not null,
  registrado_en timestamptz not null default now(),
  foreign key (activo_id, numero_activo) references public.activos (id, numero_activo) on update cascade
);
create table public.documentos (
  id uuid primary key default gen_random_uuid(),
  activo_id uuid not null, numero_activo text not null,
  inspeccion_id uuid references public.inspecciones(id),
  tipo text not null check (tipo in ('Certificado','Acta','Informe','PDF','Fotografía','Otro')),
  nombre_archivo text not null, archivo text not null, descripcion text,
  usuario_id uuid references public.perfiles(id), usuario_nombre text not null,
  subido_en timestamptz not null default now(),
  foreign key (activo_id, numero_activo) references public.activos (id, numero_activo) on update cascade
);
alter table public.activos add constraint activos_foto_principal_fk foreign key (foto_principal_id) references public.fotografias(id);

create table public.historial (
  id bigint generated always as identity primary key,
  activo_id uuid not null references public.activos(id),
  numero_activo text not null,
  fecha_hora timestamptz not null default now(),
  usuario_id uuid references public.perfiles(id),
  usuario_nombre text not null default 'Sistema',
  usuario_rol text,
  operacion text not null check (operacion in ('Alta','Modificación','Cambio de ubicación','Cambio de estado','Inspección','Reparación','Fotografía','Adjuntar documento','Baja','Reingreso','Corrección de número')),
  campo text, valor_anterior text, valor_nuevo text,
  ubicacion_anterior text, ubicacion_nueva text,
  estado_anterior text, estado_nuevo text,
  motivo text, observacion text
);
create index historial_activo_idx on public.historial (activo_id, fecha_hora desc);
create trigger trg_historial_inalterable before update or delete on public.historial
  for each row execute function public.no_eliminar();
create trigger trg_fotos_inalterables before update or delete on public.fotografias
  for each row when (pg_trigger_depth() = 0) execute function public.no_eliminar();
create trigger trg_insp_inalterables before update or delete on public.inspecciones
  for each row when (pg_trigger_depth() = 0) execute function public.no_eliminar();
create trigger trg_docs_inalterables before update or delete on public.documentos
  for each row when (pg_trigger_depth() = 0) execute function public.no_eliminar();
create trigger trg_auditoria_usuarios_inalterable before update or delete on public.auditoria_usuarios
  for each row execute function public.no_eliminar();

create or replace function public.historial_validar_numero() returns trigger
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from public.activos where id = new.activo_id and numero_activo = new.numero_activo) then
    raise exception 'El número % no corresponde al activo %', new.numero_activo, new.activo_id;
  end if;
  return new;
end $$;
create trigger trg_historial_validar_numero before insert on public.historial
  for each row execute function public.historial_validar_numero();
