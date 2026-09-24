-- 04 · Las funciones internas y de trigger no se exponen a usuarios autenticados
alter function public._exigir(text, text) set search_path = public;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f'
             and (p.proname ~ '^_' or p.proname in ('activos_asignar_numero','activos_proteger','no_eliminar','historial_validar_numero','generar_numero_activo')) loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from anon;
