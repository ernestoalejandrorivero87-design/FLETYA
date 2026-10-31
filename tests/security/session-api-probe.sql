-- Test environment only. Never install this probe in production.
create or replace function public.fletya_session_permission_probe()
returns jsonb language plpgsql security invoker set search_path='' as $probe$
declare
  actor_id uuid := auth.uid();
  actor_role text;
  target public.jobs%rowtype;
  test_case jsonb;
  tests jsonb := '[]';
  write_cases jsonb;
  passed boolean;
  touched bigint;
  error_code text;
begin
  if current_user <> 'authenticated' or actor_id is null then
    raise exception using errcode='42501',message='A signed-in client or driver is required';
  end if;
  select role into actor_role from public.profiles where id=actor_id;
  if actor_role not in ('client','driver') or actor_role is null then
    raise exception using errcode='42501',message='Use a client or driver test account';
  end if;
  select count(*)=1 into passed from public.profiles where id=actor_id;
  tests := tests || jsonb_build_array(jsonb_build_object('name','Perfil propio accesible','passed',passed));
  select count(*)=0 into passed from public.profiles where id<>actor_id;
  tests := tests || jsonb_build_array(jsonb_build_object('name','Perfiles ajenos protegidos','passed',passed));
  select count(*)=0 into passed from public.notifications where user_id is distinct from actor_id;
  tests := tests || jsonb_build_array(jsonb_build_object('name','Notificaciones ajenas protegidas','passed',passed));
  if actor_role='client' then
    select count(*)=0 into passed from public.jobs where client_id is distinct from actor_id;
    select * into target from public.jobs where client_id=actor_id order by (status='en_route') desc,created_at desc limit 1;
  else
    select count(*)=0 into passed from public.jobs
    where driver_id is distinct from actor_id and not(status='requested' and driver_id is null);
    select * into target from public.jobs where driver_id=actor_id order by (status='en_route') desc,created_at desc limit 1;
  end if;
  tests := tests || jsonb_build_array(jsonb_build_object('name','Servicios ajenos protegidos','passed',passed));
  select count(*)=0 into passed from public.driver_locations dl
  where dl.driver_id is distinct from actor_id and not exists(
    select 1 from public.jobs j where j.id=dl.job_id and j.status='en_route' and j.client_id=actor_id);
  tests := tests || jsonb_build_array(jsonb_build_object('name','Ubicaciones ajenas protegidas','passed',passed));
  write_cases := jsonb_build_array(jsonb_build_object('name','Cambio a administrador bloqueado',
    'sql',format('update public.profiles set role=%L where id=%L','admin',actor_id)));
  if target.id is not null then
    write_cases := write_cases || jsonb_build_array(
      jsonb_build_object('name','Cambio de precio bloqueado','sql',format('update public.jobs set price=coalesce(price,0)+1 where id=%L',target.id)),
      jsonb_build_object('name','Cambio de destino bloqueado','sql',format('update public.jobs set destination=destination || %L where id=%L',' [permission probe]',target.id)),
      jsonb_build_object('name','Cambio de pago bloqueado','sql',format('update public.jobs set driver_paid=not coalesce(driver_paid,false) where id=%L',target.id)));
  end if;
  for test_case in select value from jsonb_array_elements(write_cases) loop
    passed:=false; error_code:=null;
    begin
      execute test_case->>'sql';
      get diagnostics touched=ROW_COUNT;
      passed := touched=0;
      raise exception using errcode='ZX001',message='Rollback permission probe';
    exception
      when sqlstate 'ZX001' then null;
      when insufficient_privilege then passed:=true; error_code:=SQLSTATE;
      when raise_exception then
        passed := SQLERRM in ('Only an administrator can change profile roles','Drivers cannot edit job details or payment flags','This account is not authorized to update jobs','Drivers may only accept available jobs or complete their own in-route job');
        error_code:=SQLSTATE;
      when others then passed:=false; error_code:=SQLSTATE;
    end;
    tests := tests || jsonb_build_array(jsonb_build_object('name',test_case->>'name','passed',passed,'code',error_code));
  end loop;
  return jsonb_build_object('version',1,'role',actor_role,'tested_job_status',target.status,
    'active_job_tested',target.status='en_route','writes_rolled_back',true,
    'tests',tests,'all_passed',not exists(select 1 from jsonb_array_elements(tests) t where (t->>'passed')::boolean is not true));
end $probe$;
revoke all on function public.fletya_session_permission_probe() from public,anon;
grant execute on function public.fletya_session_permission_probe() to authenticated;
notify pgrst, 'reload schema';