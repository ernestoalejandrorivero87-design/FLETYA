-- Disposable PostgreSQL fixture approximating the Supabase objects used by FLETYA migrations.
-- Never run this fixture against production.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id uuid primary key,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);

create or replace function auth.uid()
returns uuid language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function auth.role()
returns text language sql stable
as $$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;

create table public.profiles (
  id uuid primary key,
  full_name text,
  phone text,
  role text not null default 'client',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  email text
);
create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  origin text not null,
  destination text not null,
  distance_km numeric,
  vehicle_type text,
  helpers integer,
  service_type text,
  description text,
  price numeric not null default 0,
  status text not null default 'requested',
  client_id uuid not null,
  driver_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  driver_paid boolean not null default false
);
create table public.driver_locations (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null unique,
  job_id uuid not null references public.jobs(id),
  latitude double precision not null,
  longitude double precision not null,
  accuracy double precision,
  updated_at timestamptz not null default now()
);
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  title text,
  message text,
  type text,
  read boolean not null default false,
  created_at timestamptz not null default now(),
  job_id uuid
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin') $$;

create or replace function public.notify_drivers_new_job()
returns trigger language plpgsql security definer set search_path=public
as $$ begin return new; end $$;

create or replace function public.test_auth_signup()
returns trigger language plpgsql security definer set search_path=public
as $$ begin perform public.handle_new_user(); return new; end $$;

-- The production auth trigger is named on_auth_user_created and calls handle_new_user().
-- Define it after the migration creates that function.
alter table public.profiles enable row level security;
alter table public.jobs enable row level security;
alter table public.driver_locations enable row level security;
alter table public.notifications enable row level security;

create policy "Users can create their own profile" on public.profiles
for insert to authenticated with check (auth.uid()=id);
create policy "Admins can view all profiles" on public.profiles
for select to authenticated using (public.is_admin());
create policy "Users can view their own profile" on public.profiles
for select to authenticated using (auth.uid()=id);
create policy "Users can update their own profile" on public.profiles
for update to authenticated using (auth.uid()=id) with check (auth.uid()=id);

create policy "Clients can create their own jobs" on public.jobs
for insert to authenticated with check (auth.uid()=client_id);
create policy "Clients can view their own jobs" on public.jobs
for select to authenticated using (auth.uid()=client_id);
create policy "Admins can view all jobs" on public.jobs
for select to authenticated using (exists(select 1 from public.profiles where id=auth.uid() and role='admin'));
create policy "Drivers can view available jobs" on public.jobs
for select to authenticated using (status='requested' and driver_id is null or driver_id=auth.uid());
create policy "Admins can update driver payments" on public.jobs
for update to authenticated using (exists(select 1 from public.profiles where id=auth.uid() and role='admin')) with check (exists(select 1 from public.profiles where id=auth.uid() and role='admin'));
create policy "Drivers can accept available jobs v2" on public.jobs
for update to authenticated using (status='requested' and driver_id is null) with check (status='en_route' and driver_id=auth.uid());
create policy "Drivers can complete their jobs" on public.jobs
for update to authenticated using (status='en_route' and driver_id=auth.uid()) with check (status='completed' and driver_id=auth.uid());

create policy "driver_insert_location" on public.driver_locations
for insert to authenticated with check (auth.uid()=driver_id);
create policy "driver_update_location" on public.driver_locations
for update to authenticated using (auth.uid()=driver_id) with check (auth.uid()=driver_id);
create policy "view_job_driver_location" on public.driver_locations
for select to authenticated using (auth.uid()=driver_id or exists(select 1 from public.jobs j where j.id=job_id and j.status='en_route' and (j.client_id=auth.uid() or j.driver_id=auth.uid())));

create policy "users_insert_own_notifications" on public.notifications
for insert to authenticated with check (auth.uid()=user_id);
create policy "users_read_own_notifications" on public.notifications
for select to authenticated using (auth.uid()=user_id);
create policy "users_update_own_notifications" on public.notifications
for update to authenticated using (auth.uid()=user_id) with check (auth.uid()=user_id);

grant usage on schema public, auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant execute on function auth.role() to anon, authenticated;
grant select, insert, update, delete, truncate, references, trigger on all tables in schema public to anon, authenticated;
grant select, insert, update, delete on auth.users to authenticated;

create trigger trigger_notify_drivers_new_job
after insert on public.jobs for each row execute function public.notify_drivers_new_job();
