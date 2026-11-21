alter table public.profiles
 add column if not exists vehicle_payload_kg numeric(8,2),
 add column if not exists vehicle_cargo_length_cm integer,
 add column if not exists vehicle_cargo_width_cm integer,
 add column if not exists vehicle_cargo_height_cm integer;
alter table public.profiles add constraint driver_vehicle_capacity_v2_check check (
 (vehicle_payload_kg is null or (role='driver' and vehicle_payload_kg>0 and vehicle_payload_kg<=20000))
 and (vehicle_cargo_length_cm is null or (role='driver' and vehicle_cargo_length_cm between 1 and 3000))
 and (vehicle_cargo_width_cm is null or (role='driver' and vehicle_cargo_width_cm between 1 and 1000))
 and (vehicle_cargo_height_cm is null or (role='driver' and vehicle_cargo_height_cm between 1 and 1000))
);