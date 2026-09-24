-- =====================================================================
--  03 · Datos iniciales: catálogos, permisos y los 25 activos de
--  "STOCK Neuquén.xlsx" (códigos originales conservados como código anterior)
-- =====================================================================
insert into public.permisos (clave, descripcion, orden) values
  ('alta', 'Dar de alta activos', 10), ('editar', 'Editar datos de activos', 20), ('mover', 'Registrar movimientos', 30),
  ('estado', 'Cambiar estado', 40), ('inspeccion', 'Registrar inspecciones', 50), ('foto', 'Cargar fotografías', 60),
  ('documento', 'Adjuntar documentos', 70), ('novedad', 'Registrar novedades y reparaciones', 80), ('baja', 'Dar de baja activos', 90),
  ('reingreso', 'Registrar reingresos', 100), ('corregir_numero', 'Corrección administrativa del número de activo', 110),
  ('importar', 'Importar Excel', 120), ('configuracion', 'Catálogos y configuración', 130), ('usuarios', 'Administrar usuarios y permisos', 140);

insert into public.paises (nombre) values ('Argentina');
insert into public.provincias (pais_id, nombre) select id, p from public.paises, unnest(array['Neuquén','Río Negro','Chubut']) p;
insert into public.localidades (provincia_id, nombre)
  select pr.id, l.loc from public.provincias pr join (values ('Neuquén','Neuquén'),('Neuquén','Añelo'),('Río Negro','Cipolletti'),('Chubut','Comodoro Rivadavia')) l(prov, loc) on pr.nombre = l.prov;
insert into public.bases (localidad_id, nombre)
  select lo.id, b.base from public.localidades lo join (values ('Neuquén','Base Z1'),('Añelo','Base N2'),('Cipolletti','Base R1'),('Comodoro Rivadavia','Base C1')) b(loc, base) on lo.nombre = b.loc;
insert into public.sectores (nombre, orden) values ('Sin asignar',1),('Taller',2),('Depósito',3),('Pañol',4),('Playa de equipos',5),('Boca de pozo',6);
insert into public.estados (nombre, critico, orden) values ('Nuevo',false,1),('Operativo',false,2),('Precintado',false,3),('Sin precinto',false,4),
  ('En inspección',false,5),('En reparación',false,6),('Fuera de servicio',true,7),('Baja',true,99);
insert into public.tipos_herramienta (nombre) values ('Elevador de varilla'),('Gancho varilla'),('Elevador de tubing'),('Elevador de bomba'),('Gancho Shur-Loc'),('Destorcedor');
insert into public.empresas_inspeccion (nombre) values ('Molise'),('Amarillo'),('Tuboscope'),('Aries');
insert into public.configuracion values ('alerta_dias', '30');

-- 25 activos (el número ACT se asigna automáticamente, en el orden del Excel)
do $$
declare r record; a public.activos;
  v_prov int := (select id from public.provincias where nombre = 'Neuquén');
  v_base int := (select b.id from public.bases b join public.localidades l on l.id = b.localidad_id where l.nombre = 'Neuquén' and b.nombre = 'Base Z1');
  v_sec int := (select id from public.sectores where nombre = 'Sin asignar');
begin
  for r in select * from (values
    (1,'NQN-EV-001','Elevador de varilla','Molise','013322',null,'Precintado'),(2,'NQN-EV-002','Elevador de varilla','Amarillo','9334962',null,'Precintado'),
    (3,'NQN-EV-003','Elevador de varilla','Molise','006157',null,'Precintado'),(4,'NQN-EV-004','Elevador de varilla','Amarillo','9334986',null,'Precintado'),
    (5,'NQN-EV-005','Elevador de varilla','Molise','009289',null,'Precintado'),(6,'NQN-EV-006','Elevador de varilla','Molise','013387',null,'Precintado'),
    (7,'NQN-GV-001','Gancho varilla','Tuboscope','003498',null,'Precintado'),(8,'NQN-GV-002','Gancho varilla','Tuboscope','124255','35 TON','Precintado'),
    (9,'NQN-GV-003','Gancho varilla',null,null,'35 TON','Sin precinto'),(10,'NQN-ET-001','Elevador de tubing','Tuboscope','124199','3 1/2"','Precintado'),
    (11,'NQN-ET-002','Elevador de tubing','Molise','005975','2 3/8"','Precintado'),(12,'NQN-ET-003','Elevador de tubing',null,null,'2 7/8"','Sin precinto'),
    (13,'NQN-ET-004','Elevador de tubing',null,null,'2 7/8"','Sin precinto'),(14,'NQN-ET-005','Elevador de tubing',null,null,'2 7/8"','Sin precinto'),
    (15,'NQN-ET-006','Elevador de tubing',null,null,'2 3/8"','Sin precinto'),(16,'NQN-ET-007','Elevador de tubing',null,null,'3 3/8"','Sin precinto'),
    (17,'NQN-EB-001','Elevador de bomba','Molise','005788',null,'Precintado'),(18,'NQN-EB-002','Elevador de bomba','Molise','010972',null,'Precintado'),
    (19,'NQN-EB-003','Elevador de bomba','Molise','010965',null,'Precintado'),(20,'NQN-GS-001','Gancho Shur-Loc','Molise','013357',null,'Precintado'),
    (21,'NQN-GS-002','Gancho Shur-Loc',null,null,null,'Nuevo'),(22,'NQN-GS-003','Gancho Shur-Loc',null,null,null,'Nuevo'),
    (23,'NQN-GS-004','Gancho Shur-Loc',null,null,null,'Nuevo'),(24,'NQN-GS-005','Gancho Shur-Loc',null,null,null,'Nuevo'),
    (25,'NQN-DT-001','Destorcedor','Aries','0009300','5 TON','Precintado')
  ) v(n, cod, tipo, emp, prec, med, est) order by n loop
    insert into public.activos (numero_activo, codigo_anterior, tipo_id, numero_precinto, medida, empresa_inspeccion_id, provincia_origen_id, base_id, sector_id, estado_id)
    values ('ACT-000000', r.cod, (select id from public.tipos_herramienta where nombre = r.tipo), r.prec, r.med,
            (select id from public.empresas_inspeccion where nombre = r.emp), v_prov, v_base, v_sec, (select id from public.estados where nombre = r.est))
    returning * into a;
    insert into public.historial (activo_id, numero_activo, usuario_nombre, operacion, estado_nuevo, ubicacion_nueva, observacion)
    values (a.id, a.numero_activo, 'Sistema (importación)', 'Alta', r.est, public._ub_texto(v_base, v_sec, null),
            'Importado desde STOCK Neuquén.xlsx · código anterior ' || r.cod);
  end loop;
end $$;
