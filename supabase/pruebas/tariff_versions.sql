create table public.fletya_tariff_versions (
 id uuid primary key default gen_random_uuid(),
 created_at timestamptz not null default clock_timestamp(),
 effective_at timestamptz not null default clock_timestamp(),
 created_by uuid default auth.uid(),
 reason text not null check (length(trim(reason)) between 3 and 500),
 included_km numeric(8,2) not null check (included_km between 0 and 100),
 parcel_base numeric(10,2) not null check (parcel_base between 1 and 100000),
 parcel_km numeric(10,2) not null check (parcel_km between 0 and 10000),
 moving_base numeric(10,2) not null check (moving_base between 1 and 100000),
 moving_km numeric(10,2) not null check (moving_km between 0 and 10000),
 materials_base numeric(10,2) not null check (materials_base between 1 and 100000),
 materials_km numeric(10,2) not null check (materials_km between 0 and 10000),
 helper_price numeric(10,2) not null check (helper_price between 0 and 10000),
 helper_hours numeric(5,2) not null check (helper_hours between 0.5 and 24),
 helper_overtime numeric(10,2) not null check (helper_overtime between 0 and 10000),
 commission_percent numeric(5,2) not null default 15 check (commission_percent=15)
);
alter table public.fletya_tariff_versions enable row level security;
revoke all on public.fletya_tariff_versions from public,anon,authenticated;
grant select,insert on public.fletya_tariff_versions to authenticated;
create policy tariff_admin_read on public.fletya_tariff_versions for select to authenticated using ((select private.is_admin()));
create policy tariff_admin_insert on public.fletya_tariff_versions for insert to authenticated with check ((select private.is_admin()) and created_by=(select auth.uid()));
insert into public.fletya_tariff_versions(reason,included_km,parcel_base,parcel_km,moving_base,moving_km,materials_base,materials_km,helper_price,helper_hours,helper_overtime) values ('Configuración inicial aprobada para Pruebas',3,400,45,500,50,550,55,300,2,150);