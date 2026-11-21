create or replace function public.notify_drivers_new_job() returns trigger language plpgsql security definer set search_path to '' as $$
begin
 if new.status='requested' and new.driver_id is null then
   insert into public.notifications(user_id,title,message,type,job_id)
   select p.id,'🚚 Nueva solicitud de flete','Hay un nuevo servicio disponible para aceptar.','info',new.id
   from public.profiles p
   where p.role='driver'
     and (new.vehicle_type not in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t')
       or new.vehicle_type is null
       or (p.driver_status='approved' and private.vehicle_request_matches_v2(new.vehicle_type,p.vehicle_type)));
 end if;
 return new;
end;
$$;