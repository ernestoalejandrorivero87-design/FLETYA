-- FLETYA security hardening: prevent self-assignment or self-promotion to admin.
-- Review and apply only through a controlled Supabase migration after testing.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'phone',
    case
      when new.raw_user_meta_data ->> 'role' = 'driver' then 'driver'
      else 'client'
    end
  );

  return new;
end;
$function$;

create or replace function public.guard_profile_role_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and not public.is_admin() then
      raise exception 'Profiles are created by the sign-up process';
    end if;
  elsif new.role is distinct from old.role
        and auth.uid() is not null
        and not public.is_admin() then
    raise exception 'Only an administrator can change profile roles';
  end if;

  return new;
end;
$function$;

revoke all on function public.guard_profile_role_changes() from public;
revoke all on function public.guard_profile_role_changes() from anon;
revoke all on function public.guard_profile_role_changes() from authenticated;

drop trigger if exists guard_profile_role_changes on public.profiles;
create trigger guard_profile_role_changes
before insert or update of role on public.profiles
for each row
execute function public.guard_profile_role_changes();
