-- Keep the admin helper available to RLS without exposing it as a public PostgREST RPC.
-- Apply in non-production first and verify administrator profile access before any production rollout.

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;
grant usage on schema private to authenticated;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  )
$function$;

revoke all on function private.is_admin() from public;
revoke all on function private.is_admin() from anon;
grant execute on function private.is_admin() to authenticated;

alter policy "Admins can view all profiles"
  on public.profiles
  using (private.is_admin());

create or replace function public.guard_profile_role_changes()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $function$
begin
  if tg_op = 'INSERT' then
    if pg_trigger_depth() = 1 and auth.uid() is not null and not private.is_admin() then
      raise exception 'Profiles are created by the sign-up process';
    end if;
  elsif new.role is distinct from old.role and auth.uid() is not null and not private.is_admin() then
    raise exception 'Only an administrator can change profile roles';
  end if;
  return new;
end;
$function$;

drop function public.is_admin();
