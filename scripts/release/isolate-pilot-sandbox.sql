create table private.pilot_card_participants(user_id uuid primary key references auth.users(id) on delete cascade);
alter table private.pilot_card_participants enable row level security;
revoke all on private.pilot_card_participants from public,anon,authenticated,service_role;
create function private.pilot_card_participant() returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from private.pilot_card_participants p where p.user_id=auth.uid()) $$;
revoke all on function private.pilot_card_participant() from public,anon;
grant execute on function private.pilot_card_participant() to authenticated;
create policy pilot_sandbox_isolation on public.jobs as restrictive for all to authenticated using (sandbox_payment_method is null or client_id=auth.uid() or driver_id=auth.uid() or private.is_admin() or private.pilot_card_participant()) with check (sandbox_payment_method is null or client_id=auth.uid() or driver_id=auth.uid() or private.is_admin() or private.pilot_card_participant());
create or replace function public.notify_drivers_new_job() returns trigger language plpgsql security definer set search_path='public' as $$
begin
 if new.status='requested' and new.driver_id is null then
 insert into public.notifications(user_id,title,message,type,job_id)
 select p.id,'🚚 Nueva solicitud de flete','Hay un nuevo servicio disponible para aceptar.','info',new.id from public.profiles p where p.role='driver' and (new.sandbox_payment_method is null or exists(select 1 from private.pilot_card_participants a where a.user_id=p.id));
 end if;
 return new;
end $$;