create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path to '' as $function$
declare driver boolean := new.raw_user_meta_data->>'role'='driver'; vehicle text := new.raw_user_meta_data->>'vehicle_type'; plate text := upper(trim(new.raw_user_meta_data->>'plates'));
begin
 insert into public.profiles(id,full_name,phone,role,email,vehicle_type,plates,driver_status)
 values(new.id,left(trim(new.raw_user_meta_data->>'full_name'),100),left(trim(new.raw_user_meta_data->>'phone'),20),
 case when driver then 'driver' else 'client' end,new.email,
 case when driver and vehicle in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t','camioneta','camion') then vehicle else null end,
 case when driver and plate ~ '^[A-Z0-9 -]{3,15}$' then plate else null end,
 case when driver then 'pending' else 'approved' end);
 return new;
end $function$;