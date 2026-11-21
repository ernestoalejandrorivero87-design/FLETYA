alter table public.profiles drop constraint driver_vehicle_identity_check;
alter table public.profiles add constraint driver_vehicle_identity_check check (
 (vehicle_type is null or (role='driver' and vehicle_type in ('pickup','camioneta','camion','estaquita_abierta','estaquita_caja_seca','camion_3_5t')))
 and (plates is null or (role='driver' and plates ~ '^[A-Z0-9 -]{3,15}$' and plates=btrim(plates)))
);
