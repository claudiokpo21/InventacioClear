-- =====================================================================
--  02 · Seguridad (RLS), permisos y operaciones
--  Toda escritura pasa por funciones que validan el permiso del usuario
--  y registran el historial en la misma transacción.
-- =====================================================================

-- ---------- Funciones de acceso ----------
create or replace function public.tiene_acceso() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and activo)
$$;
create or replace function public.tiene_permiso(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.perfiles pf
    where pf.id = auth.uid() and pf.activo
      and (pf.rol = 'Administrador' or exists (select 1 from public.perfil_permisos pp where pp.perfil_id = pf.id and pp.permiso = p))
  )
$$;
create or replace function public._requerir(p text) returns public.perfiles
language plpgsql stable security definer set search_path = public as $$
declare yo public.perfiles;
begin
  select * into yo from public.perfiles where id = auth.uid() and activo;
  if yo.id is null then raise exception 'Usuario sin acceso o deshabilitado' using errcode = '42501'; end if;
  if not public.tiene_permiso(p) then
    raise exception 'Tu usuario no tiene el permiso "%"', (select descripcion from public.permisos where clave = p) using errcode = '42501';
  end if;
  return yo;
end $$;
create or replace function public.mis_permisos() returns text[]
language sql stable security definer set search_path = public as $$
  select case when pf.rol = 'Administrador' then (select array_agg(clave order by orden) from public.permisos)
              else coalesce((select array_agg(permiso) from public.perfil_permisos where perfil_id = pf.id), '{}') end
  from public.perfiles pf where pf.id = auth.uid() and pf.activo
$$;

-- ---------- Resolución de catálogos por nombre ----------
create or replace function public._base_id(p_prov text, p_loc text, p_base text) returns int
language plpgsql stable set search_path = public as $$
declare r int;
begin
  select b.id into r from public.bases b join public.localidades l on l.id = b.localidad_id join public.provincias p on p.id = l.provincia_id
   where p.nombre = p_prov and l.nombre = p_loc and b.nombre = p_base;
  if r is null then raise exception 'Ubicación inexistente: % › % › %', p_prov, p_loc, p_base; end if;
  return r;
end $$;
create or replace function public._id_catalogo(p_tabla text, p_nombre text, p_crear boolean default false) returns int
language plpgsql set search_path = public as $$
declare r int;
begin
  if coalesce(trim(p_nombre), '') = '' then return null; end if;
  execute format('select id from public.%I where nombre = $1', p_tabla) into r using trim(p_nombre);
  if r is null and p_crear then
    execute format('insert into public.%I (nombre) values ($1) returning id', p_tabla) into r using trim(p_nombre);
  end if;
  if r is null then raise exception 'Valor inexistente en %: %', p_tabla, p_nombre; end if;
  return r;
end $$;
create or replace function public._ub_texto(p_base int, p_sector int, p_esp text) returns text
language sql stable set search_path = public as $$
  select concat_ws(' · ', b.nombre, s.nombre, nullif(p_esp, '')) || ' — ' || l.nombre || ', ' || p.nombre
  from public.bases b join public.localidades l on l.id = b.localidad_id join public.provincias p on p.id = l.provincia_id
  join public.sectores s on s.id = p_sector where b.id = p_base
$$;
create or replace function public._log(p_activo uuid, p_op text, p_yo public.perfiles, p_extra jsonb default '{}') returns void
language plpgsql set search_path = public as $$
begin
  insert into public.historial (activo_id, numero_activo, usuario_id, usuario_nombre, usuario_rol, operacion, campo, valor_anterior, valor_nuevo,
                                ubicacion_anterior, ubicacion_nueva, estado_anterior, estado_nuevo, motivo, observacion)
  select a.id, a.numero_activo, p_yo.id, coalesce(p_yo.nombre, 'Sistema'), p_yo.rol, p_op,
         p_extra->>'campo', p_extra->>'ant', p_extra->>'nue', p_extra->>'ubAnt', p_extra->>'ubNue',
         p_extra->>'estadoAnt', p_extra->>'estadoNue', nullif(p_extra->>'motivo', ''), nullif(p_extra->>'obs', '')
  from public.activos a where a.id = p_activo;
end $$;
create or replace function public._activo(p_id uuid) returns public.activos
language plpgsql set search_path = public as $$
declare a public.activos;
begin
  select * into a from public.activos where id = p_id for update;
  if a.id is null then raise exception 'Activo inexistente'; end if;
  return a;
end $$;
create or replace function public._exigir(p_valor text, p_campo text) returns text
language plpgsql immutable as $$
begin
  if coalesce(trim(p_valor), '') = '' then raise exception '% es obligatorio', p_campo; end if;
  return trim(p_valor);
end $$;

-- ---------- Operaciones sobre activos ----------
create or replace function public.alta_activo(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('alta'); a public.activos; v_base int; v_prov int; v_insp uuid;
begin
  v_base := public._base_id(p->>'prov', p->>'loc', p->>'base');
  select l.provincia_id into v_prov from public.bases b join public.localidades l on l.id = b.localidad_id where b.id = v_base;
  insert into public.activos (tipo_id, marca, modelo, numero_serie, numero_precinto, medida, empresa_inspeccion_id, responsable,
                              provincia_origen_id, base_id, sector_id, ubicacion_especifica, estado_id, observaciones, fecha_alta, creado_por, numero_activo)
  values (public._id_catalogo('tipos_herramienta', public._exigir(p->>'tipo', 'El tipo de herramienta'), true),
          nullif(trim(p->>'marca'), ''), nullif(trim(p->>'modelo'), ''), nullif(trim(p->>'serie'), ''), nullif(trim(p->>'precinto'), ''),
          nullif(trim(p->>'medida'), ''), public._id_catalogo('empresas_inspeccion', p->>'empresa', true), nullif(trim(p->>'responsable'), ''),
          v_prov, v_base, public._id_catalogo('sectores', coalesce(nullif(p->>'sector', ''), 'Sin asignar')), nullif(trim(p->>'esp'), ''),
          public._id_catalogo('estados', coalesce(nullif(p->>'estado', ''), 'Nuevo')), nullif(trim(p->>'obs'), ''),
          coalesce(nullif(p->>'alta', '')::date, current_date), yo.id, 'ACT-000000')
  returning * into a;
  if (select nombre from public.estados where id = a.estado_id) = 'Baja' then raise exception 'Un alta no puede quedar en estado Baja'; end if;
  perform public._log(a.id, 'Alta', yo, jsonb_build_object('estadoNue', (select nombre from public.estados where id = a.estado_id),
                                                             'ubNue', public._ub_texto(a.base_id, a.sector_id, a.ubicacion_especifica), 'obs', 'Alta del activo'));
  if nullif(p->>'insp_venc', '') is not null then
    insert into public.inspecciones (activo_id, numero_activo, empresa_inspeccion_id, fecha, fecha_vencimiento, resultado, numero_certificado, usuario_id, usuario_nombre)
    values (a.id, a.numero_activo, a.empresa_inspeccion_id, coalesce(nullif(p->>'insp_fecha', '')::date, current_date), (p->>'insp_venc')::date,
            'Aprobada', nullif(trim(p->>'insp_cert'), ''), yo.id, yo.nombre) returning id into v_insp;
    perform public._log(a.id, 'Inspección', yo, jsonb_build_object('campo', 'Inspección', 'nue', 'Aprobada · vence ' || to_char((p->>'insp_venc')::date, 'DD/MM/YYYY'), 'obs', 'Inspección inicial'));
  end if;
  return jsonb_build_object('id', a.id, 'numero_activo', a.numero_activo);
end $$;

create or replace function public.editar_activo(p_id uuid, p jsonb, p_motivo text) returns int
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('editar'); a public.activos := public._activo(p_id); n int := 0;
        k text; l text; ant text; nue text;
begin
  if a.dado_de_baja then raise exception 'El activo está dado de baja'; end if;
  for k, l in select * from (values ('tipo','Tipo de herramienta'),('marca','Marca'),('modelo','Modelo'),('serie','N° de serie'),('precinto','N° precinto'),
                                    ('medida','Medida'),('empresa','Empresa de inspección'),('responsable','Responsable'),('obs','Observaciones')) v(k, l) loop
    if not (p ? k) then continue; end if;
    ant := case k when 'tipo' then (select nombre from public.tipos_herramienta where id = a.tipo_id) when 'marca' then a.marca when 'modelo' then a.modelo
                  when 'serie' then a.numero_serie when 'precinto' then a.numero_precinto when 'medida' then a.medida
                  when 'empresa' then (select nombre from public.empresas_inspeccion where id = a.empresa_inspeccion_id)
                  when 'responsable' then a.responsable when 'obs' then a.observaciones end;
    nue := nullif(trim(p->>k), '');
    if coalesce(ant, '') = coalesce(nue, '') then continue; end if;
    case k
      when 'tipo' then update public.activos set tipo_id = public._id_catalogo('tipos_herramienta', public._exigir(nue, 'El tipo'), true) where id = p_id;
      when 'marca' then update public.activos set marca = nue where id = p_id;
      when 'modelo' then update public.activos set modelo = nue where id = p_id;
      when 'serie' then update public.activos set numero_serie = nue where id = p_id;
      when 'precinto' then update public.activos set numero_precinto = nue where id = p_id;
      when 'medida' then update public.activos set medida = nue where id = p_id;
      when 'empresa' then update public.activos set empresa_inspeccion_id = public._id_catalogo('empresas_inspeccion', nue, true) where id = p_id;
      when 'responsable' then update public.activos set responsable = nue where id = p_id;
      when 'obs' then update public.activos set observaciones = nue where id = p_id;
    end case;
    perform public._log(p_id, 'Modificación', yo, jsonb_build_object('campo', l, 'ant', ant, 'nue', nue, 'motivo', p_motivo));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.mover_activo(p_id uuid, p_prov text, p_loc text, p_base text, p_sector text, p_esp text, p_motivo text, p_obs text) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('mover'); a public.activos := public._activo(p_id); v_base int; v_sec int; ant text; nue text;
begin
  if a.dado_de_baja then raise exception 'El activo está dado de baja'; end if;
  perform public._exigir(p_motivo, 'El motivo');
  v_base := public._base_id(p_prov, p_loc, p_base); v_sec := public._id_catalogo('sectores', p_sector);
  ant := public._ub_texto(a.base_id, a.sector_id, a.ubicacion_especifica); nue := public._ub_texto(v_base, v_sec, nullif(trim(p_esp), ''));
  if ant = nue then raise exception 'La ubicación nueva es igual a la actual'; end if;
  update public.activos set base_id = v_base, sector_id = v_sec, ubicacion_especifica = nullif(trim(p_esp), '') where id = p_id;
  perform public._log(p_id, 'Cambio de ubicación', yo, jsonb_build_object('campo', 'Ubicación', 'ubAnt', ant, 'ubNue', nue, 'motivo', p_motivo, 'obs', p_obs));
end $$;

create or replace function public.cambiar_estado(p_id uuid, p_estado text, p_motivo text, p_obs text) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('estado'); a public.activos := public._activo(p_id); v int; ant text;
begin
  if a.dado_de_baja then raise exception 'El activo está dado de baja'; end if;
  if p_estado = 'Baja' then raise exception 'Para dar de baja use la operación Dar de baja'; end if;
  perform public._exigir(p_motivo, 'El motivo');
  v := public._id_catalogo('estados', p_estado); ant := (select nombre from public.estados where id = a.estado_id);
  if v = a.estado_id then raise exception 'El activo ya está en estado %', p_estado; end if;
  update public.activos set estado_id = v where id = p_id;
  perform public._log(p_id, 'Cambio de estado', yo, jsonb_build_object('campo', 'Estado', 'estadoAnt', ant, 'estadoNue', p_estado, 'motivo', p_motivo, 'obs', p_obs));
end $$;

create or replace function public.registrar_inspeccion(p_id uuid, p_empresa text, p_fecha date, p_venc date, p_resultado text, p_cert text, p_precinto text, p_obs text) returns uuid
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('inspeccion'); a public.activos := public._activo(p_id); r uuid; v_emp int;
begin
  if a.dado_de_baja then raise exception 'El activo está dado de baja'; end if;
  v_emp := public._id_catalogo('empresas_inspeccion', public._exigir(p_empresa, 'La empresa inspectora'), true);
  insert into public.inspecciones (activo_id, numero_activo, empresa_inspeccion_id, fecha, fecha_vencimiento, resultado, numero_certificado, observaciones, usuario_id, usuario_nombre)
  values (a.id, a.numero_activo, v_emp, p_fecha, p_venc, p_resultado, nullif(trim(p_cert), ''), nullif(trim(p_obs), ''), yo.id, yo.nombre) returning id into r;
  perform public._log(p_id, 'Inspección', yo, jsonb_build_object('campo', 'Inspección', 'nue', p_resultado || ' · vence ' || to_char(p_venc, 'DD/MM/YYYY'),
                                                                 'obs', concat_ws(' · ', p_empresa, 'Cert. ' || nullif(trim(p_cert), ''), nullif(trim(p_obs), ''))));
  if coalesce(nullif(trim(p_precinto), ''), '') <> coalesce(a.numero_precinto, '') then
    update public.activos set numero_precinto = nullif(trim(p_precinto), '') where id = p_id;
    perform public._log(p_id, 'Modificación', yo, jsonb_build_object('campo', 'N° precinto', 'ant', a.numero_precinto, 'nue', nullif(trim(p_precinto), ''), 'motivo', 'Registrado en inspección'));
  end if;
  return r;
end $$;

create or replace function public.registrar_foto(p_id uuid, p_archivo text, p_tipo text, p_obs text, p_principal boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('foto'); a public.activos := public._activo(p_id); r uuid;
begin
  if p_archivo not like p_id::text || '/%' then raise exception 'Archivo no corresponde al activo'; end if;
  insert into public.fotografias (activo_id, numero_activo, tipo, archivo, observacion, usuario_id, usuario_nombre)
  values (a.id, a.numero_activo, p_tipo, p_archivo, nullif(trim(p_obs), ''), yo.id, yo.nombre) returning id into r;
  perform public._log(p_id, 'Fotografía', yo, jsonb_build_object('campo', 'Fotografía', 'nue', p_tipo, 'obs', p_obs));
  if p_principal or a.foto_principal_id is null then update public.activos set foto_principal_id = r where id = p_id; end if;
  return r;
end $$;

create or replace function public.fijar_foto_principal(p_foto uuid) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('foto'); f public.fotografias; a public.activos;
begin
  select * into f from public.fotografias where id = p_foto; if f.id is null then raise exception 'Fotografía inexistente'; end if;
  a := public._activo(f.activo_id);
  update public.activos set foto_principal_id = f.id where id = a.id;
  perform public._log(a.id, 'Modificación', yo, jsonb_build_object('campo', 'Fotografía principal', 'ant', case when a.foto_principal_id is null then 'Sin definir' else 'Foto anterior' end,
                                                                  'nue', f.tipo || ' del ' || to_char(f.tomada_en at time zone 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY')));
end $$;

create or replace function public.registrar_documento(p_id uuid, p_archivo text, p_nombre text, p_tipo text, p_desc text, p_inspeccion uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('documento'); a public.activos := public._activo(p_id); r uuid;
begin
  if p_archivo not like p_id::text || '/%' then raise exception 'Archivo no corresponde al activo'; end if;
  insert into public.documentos (activo_id, numero_activo, inspeccion_id, tipo, nombre_archivo, archivo, descripcion, usuario_id, usuario_nombre)
  values (a.id, a.numero_activo, p_inspeccion, p_tipo, p_nombre, p_archivo, nullif(trim(p_desc), ''), yo.id, yo.nombre) returning id into r;
  perform public._log(p_id, 'Adjuntar documento', yo, jsonb_build_object('campo', 'Documento', 'nue', p_tipo || ': ' || p_nombre, 'obs', p_desc));
  return r;
end $$;

create or replace function public.registrar_novedad(p_id uuid, p_tipo text, p_detalle text) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('novedad'); a public.activos := public._activo(p_id);
begin
  perform public._exigir(p_detalle, 'El detalle');
  if p_tipo = 'rep' then perform public._log(p_id, 'Reparación', yo, jsonb_build_object('obs', p_detalle));
  else perform public._log(p_id, 'Modificación', yo, jsonb_build_object('campo', 'Observación agregada', 'nue', p_detalle)); end if;
end $$;

create or replace function public.dar_baja(p_id uuid, p_motivo text, p_obs text) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('baja'); a public.activos := public._activo(p_id); ant text;
begin
  if a.dado_de_baja then raise exception 'El activo ya está dado de baja'; end if;
  perform public._exigir(p_motivo, 'El motivo de la baja');
  ant := (select nombre from public.estados where id = a.estado_id);
  update public.activos set dado_de_baja = true, estado_id = public._id_catalogo('estados', 'Baja') where id = p_id;
  perform public._log(p_id, 'Baja', yo, jsonb_build_object('campo', 'Estado', 'estadoAnt', ant, 'estadoNue', 'Baja', 'motivo', p_motivo, 'obs', p_obs));
end $$;

create or replace function public.reingresar(p_id uuid, p_estado text, p_motivo text, p_obs text) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('reingreso'); a public.activos := public._activo(p_id);
begin
  if not a.dado_de_baja then raise exception 'El activo no está dado de baja'; end if;
  if p_estado = 'Baja' then raise exception 'Elegí un estado distinto de Baja'; end if;
  perform public._exigir(p_motivo, 'El motivo');
  update public.activos set dado_de_baja = false, estado_id = public._id_catalogo('estados', p_estado) where id = p_id;
  perform public._log(p_id, 'Reingreso', yo, jsonb_build_object('campo', 'Estado', 'estadoAnt', 'Baja', 'estadoNue', p_estado, 'motivo', p_motivo, 'obs', p_obs));
end $$;

create or replace function public.corregir_numero(p_id uuid, p_motivo text, p_autorizacion text, p_confirmacion text) returns text
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('corregir_numero'); a public.activos := public._activo(p_id); v_new text;
begin
  perform public._exigir(p_motivo, 'El motivo'); perform public._exigir(p_autorizacion, 'La autorización');
  if upper(trim(p_confirmacion)) <> a.numero_activo then raise exception 'La confirmación no coincide con el número actual'; end if;
  v_new := public.generar_numero_activo();
  insert into public.numeros_anulados (numero_activo, activo_id, anulado_por, motivo) values (a.numero_activo, a.id, yo.id, p_motivo || ' · Autorización: ' || p_autorizacion);
  perform set_config('inv.correccion_numero', 'on', true);
  update public.activos set numero_activo = v_new where id = p_id;
  perform set_config('inv.correccion_numero', 'off', true);
  perform public._log(p_id, 'Corrección de número', yo, jsonb_build_object('campo', 'Número de activo', 'ant', a.numero_activo, 'nue', v_new, 'motivo', p_motivo,
            'obs', 'Autorización: ' || p_autorizacion || '. El número ' || a.numero_activo || ' queda anulado y no se reutiliza.'));
  return v_new;
end $$;

create or replace function public.buscar_activo_por_numero(p_numero text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from (
    select id from public.activos where public.tiene_acceso() and (numero_activo = upper(trim(p_numero)) or upper(codigo_anterior) = upper(trim(p_numero)))
    union all select activo_id from public.numeros_anulados where public.tiene_acceso() and numero_activo = upper(trim(p_numero))
  ) x limit 1
$$;

-- ---------- Importación de Excel ----------
create or replace function public.importar_activos(p_filas jsonb, p_prov text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('importar'); f jsonb; v_prov int; v_loc int; v_base int; n int := 0; omit int := 0; a public.activos; v_est text;
begin
  select id into v_prov from public.provincias where nombre = p_prov; if v_prov is null then raise exception 'Provincia inexistente'; end if;
  for f in select * from jsonb_array_elements(p_filas) loop
    if nullif(f->>'cod', '') is not null and exists (select 1 from public.activos where upper(codigo_anterior) = upper(f->>'cod')) then omit := omit + 1; continue; end if;
    if coalesce(nullif(f->>'tipo', ''), '') = '' then omit := omit + 1; continue; end if;
    insert into public.localidades (provincia_id, nombre) values (v_prov, coalesce(nullif(trim(f->>'loc'), ''), p_prov)) on conflict (provincia_id, nombre) do nothing;
    select id into v_loc from public.localidades where provincia_id = v_prov and nombre = coalesce(nullif(trim(f->>'loc'), ''), p_prov);
    insert into public.bases (localidad_id, nombre) values (v_loc, coalesce(nullif(regexp_replace(trim(f->>'base'), '\s+(NQN|RN|CHU|CHB)$', '', 'i'), ''), 'Sin base')) on conflict (localidad_id, nombre) do nothing;
    select id into v_base from public.bases where localidad_id = v_loc and nombre = coalesce(nullif(regexp_replace(trim(f->>'base'), '\s+(NQN|RN|CHU|CHB)$', '', 'i'), ''), 'Sin base');
    v_est := coalesce(nullif(trim(f->>'estado'), ''), 'Nuevo');
    insert into public.estados (nombre) values (v_est) on conflict (nombre) do nothing;
    insert into public.activos (numero_activo, codigo_anterior, tipo_id, marca, numero_precinto, medida, empresa_inspeccion_id, provincia_origen_id, base_id, sector_id, estado_id, observaciones, creado_por, dado_de_baja)
    values ('ACT-000000', nullif(trim(f->>'cod'), ''), public._id_catalogo('tipos_herramienta', f->>'tipo', true), nullif(trim(f->>'marca'), ''), nullif(trim(f->>'precinto'), ''),
            nullif(trim(f->>'medida'), ''), public._id_catalogo('empresas_inspeccion', f->>'empresa', true), v_prov, v_base, public._id_catalogo('sectores', 'Sin asignar'),
            public._id_catalogo('estados', v_est), nullif(trim(f->>'obs'), ''), yo.id, v_est = 'Baja')
    returning * into a;
    perform public._log(a.id, 'Alta', yo, jsonb_build_object('estadoNue', v_est, 'ubNue', public._ub_texto(a.base_id, a.sector_id, null),
             'obs', 'Importado desde Excel' || coalesce(' · código anterior ' || a.codigo_anterior, '')));
    n := n + 1;
  end loop;
  return jsonb_build_object('importados', n, 'omitidos', omit);
end $$;

-- ---------- Catálogos y configuración ----------
create or replace function public.agregar_catalogo(p_tipo text, p_nombre text, p_prov text default null, p_loc text default null, p_critico boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('configuracion'); v_n text := public._exigir(p_nombre, 'El nombre');
begin
  case p_tipo
    when 'provincia' then insert into public.provincias (pais_id, nombre) select id, v_n from public.paises where nombre = 'Argentina' on conflict do nothing;
    when 'localidad' then insert into public.localidades (provincia_id, nombre) select id, v_n from public.provincias where nombre = p_prov on conflict do nothing;
    when 'base' then insert into public.bases (localidad_id, nombre) select l.id, v_n from public.localidades l join public.provincias p on p.id = l.provincia_id where p.nombre = p_prov and l.nombre = p_loc on conflict do nothing;
    when 'sector' then insert into public.sectores (nombre) values (v_n) on conflict do nothing;
    when 'estado' then insert into public.estados (nombre, critico, orden) values (v_n, p_critico, 90) on conflict do nothing;
    when 'tipo' then insert into public.tipos_herramienta (nombre) values (v_n) on conflict do nothing;
    when 'empresa' then insert into public.empresas_inspeccion (nombre) values (v_n) on conflict do nothing;
    else raise exception 'Catálogo desconocido';
  end case;
end $$;
create or replace function public.configurar(p_clave text, p_valor text) returns void
language plpgsql security definer set search_path = public as $$
declare yo public.perfiles := public._requerir('configuracion');
begin
  if p_clave not in ('alerta_dias') then raise exception 'Parámetro desconocido'; end if;
  insert into public.configuracion values (p_clave, p_valor) on conflict (clave) do update set valor = excluded.valor;
end $$;
create or replace function public.marcar_clave_cambiada() returns void
language sql security definer set search_path = public as $$
  update public.perfiles set debe_cambiar_clave = false, actualizado_en = now() where id = auth.uid()
$$;

-- ---------- Vistas de lectura ----------
create view public.v_activos with (security_invoker = true) as
select a.id, a.numero_activo, a.codigo_anterior, t.nombre as tipo, a.marca, a.modelo, a.numero_serie, a.numero_precinto, a.medida,
       e.nombre as empresa, a.responsable, po.nombre as provincia_origen, 'Argentina'::text as pais, p.nombre as provincia, l.nombre as localidad,
       b.nombre as base, s.nombre as sector, a.ubicacion_especifica, es.nombre as estado, a.dado_de_baja, a.foto_principal_id,
       a.observaciones, a.fecha_alta, a.creado_en,
       (select coalesce(array_agg(n.numero_activo order by n.anulado_en), '{}') from public.numeros_anulados n where n.activo_id = a.id) as numeros_anulados
from public.activos a
join public.tipos_herramienta t on t.id = a.tipo_id
left join public.empresas_inspeccion e on e.id = a.empresa_inspeccion_id
join public.provincias po on po.id = a.provincia_origen_id
join public.bases b on b.id = a.base_id join public.localidades l on l.id = b.localidad_id join public.provincias p on p.id = l.provincia_id
join public.sectores s on s.id = a.sector_id join public.estados es on es.id = a.estado_id;

create view public.v_inspecciones with (security_invoker = true) as
select i.id, i.activo_id, i.numero_activo, e.nombre as empresa, i.fecha, i.fecha_vencimiento, i.resultado, i.numero_certificado, i.observaciones, i.usuario_nombre, i.registrado_en
from public.inspecciones i left join public.empresas_inspeccion e on e.id = i.empresa_inspeccion_id;

create view public.v_geo with (security_invoker = true) as
select p.nombre as provincia, l.nombre as localidad, b.nombre as base
from public.provincias p left join public.localidades l on l.provincia_id = p.id left join public.bases b on b.localidad_id = l.id;

-- ---------- Row Level Security ----------
do $$
declare t text;
begin
  foreach t in array array['paises','provincias','localidades','bases','sectores','estados','tipos_herramienta','empresas_inspeccion','configuracion','permisos',
                           'activos','fotografias','inspecciones','documentos','historial','numeros_anulados','perfiles','perfil_permisos','auditoria_usuarios'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
  foreach t in array array['paises','provincias','localidades','bases','sectores','estados','tipos_herramienta','empresas_inspeccion','configuracion','permisos',
                           'activos','fotografias','inspecciones','documentos','historial','numeros_anulados','perfiles'] loop
    execute format('create policy lectura_usuarios_activos on public.%I for select to authenticated using (public.tiene_acceso())', t);
  end loop;
end $$;
create policy lectura_permisos on public.perfil_permisos for select to authenticated using (perfil_id = auth.uid() or public.tiene_permiso('usuarios'));
create policy lectura_auditoria on public.auditoria_usuarios for select to authenticated using (public.tiene_permiso('usuarios'));
revoke all on public.v_activos, public.v_inspecciones, public.v_geo from anon;
revoke usage, select on sequence public.activo_numero_seq from anon, authenticated;

-- ---------- Funciones: solo usuarios autenticados ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname !~ '^_' and f.proname not in ('activos_asignar_numero','activos_proteger','no_eliminar','historial_validar_numero','generar_numero_activo') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;

-- ---------- Almacenamiento de fotos y documentos (privado) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidencias', 'evidencias', false, 20971520,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf','application/msword',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-excel',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/plain'])
on conflict (id) do nothing;
create policy evidencias_lectura on storage.objects for select to authenticated
  using (bucket_id = 'evidencias' and public.tiene_acceso());
create policy evidencias_carga on storage.objects for insert to authenticated
  with check (bucket_id = 'evidencias' and (public.tiene_permiso('foto') or public.tiene_permiso('documento'))
              and exists (select 1 from public.activos a where a.id::text = (storage.foldername(name))[1]));
