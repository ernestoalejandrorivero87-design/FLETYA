-- Read-only release inventory: metadata only, no application rows or Auth secrets.
select jsonb_build_object(
 'tables',(select jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,'kind',c.relkind,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity) order by n.nspname,c.relname)
   from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind in ('r','v','m')),
 'columns',(select jsonb_agg(jsonb_build_object('table',table_name,'name',column_name,'type',data_type,'nullable',is_nullable,'default',column_default) order by table_name,ordinal_position)
   from information_schema.columns where table_schema='public'),
 'policies',(select jsonb_agg(to_jsonb(p) order by tablename,policyname) from pg_policies p where schemaname='public'),
 'grants',(select jsonb_agg(to_jsonb(g) order by table_name,grantee,privilege_type) from information_schema.role_table_grants g
   where table_schema='public' and grantee in ('anon','authenticated','PUBLIC')),
 'column_grants',(select jsonb_agg(to_jsonb(g) order by table_name,column_name,grantee,privilege_type) from information_schema.column_privileges g
   where table_schema='public' and grantee in ('anon','authenticated','PUBLIC')),
 'functions',(select jsonb_agg(jsonb_build_object('schema',n.nspname,'name',p.proname,'args',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid),'acl',p.proacl) order by n.nspname,p.proname)
   from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prokind='f'),
 'triggers',(select jsonb_agg(jsonb_build_object('table',tgrelid::regclass::text,'name',tgname,'definition',pg_get_triggerdef(oid)) order by tgrelid::regclass::text,tgname)
   from pg_trigger where not tgisinternal and (tgrelid in ('public.profiles'::regclass,'public.jobs'::regclass,'public.driver_locations'::regclass,'public.notifications'::regclass,'auth.users'::regclass))),
 'constraints',(select jsonb_agg(jsonb_build_object('table',conrelid::regclass::text,'name',conname,'definition',pg_get_constraintdef(oid)) order by conrelid::regclass::text,conname)
   from pg_constraint where conrelid in ('public.profiles'::regclass,'public.jobs'::regclass,'public.driver_locations'::regclass,'public.notifications'::regclass)),
 'default_acl',(select jsonb_agg(jsonb_build_object('owner',r.rolname,'schema',n.nspname,'type',a.defaclobjtype,'acl',a.defaclacl) order by r.rolname,n.nspname,a.defaclobjtype)
   from pg_default_acl a join pg_roles r on r.oid=a.defaclrole left join pg_namespace n on n.oid=a.defaclnamespace)
) as inventory;
