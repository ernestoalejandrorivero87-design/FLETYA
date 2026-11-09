-- Additive push delivery. No existing job/profile/location/notification rows are modified.
create table public.driver_push_devices (
 user_id uuid not null references auth.users(id) on delete cascade,
 installation_id uuid not null,
 registration_nonce uuid not null,
 token text not null check (char_length(token) between 20 and 4096),
 session_id uuid not null,
 enabled boolean not null default true,
 updated_at timestamptz not null default now(),
 primary key(user_id,installation_id)
);
alter table public.driver_push_devices enable row level security;
revoke all on public.driver_push_devices from public,anon,authenticated;
grant select,delete on public.driver_push_devices to authenticated;
grant insert(user_id,installation_id,registration_nonce,token,enabled),update(user_id,installation_id,registration_nonce,token,enabled) on public.driver_push_devices to authenticated;
grant all on public.driver_push_devices to service_role;
create policy driver_owns_push_device on public.driver_push_devices to authenticated
 using(user_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'))
 with check(user_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='driver'));
create function private.stamp_driver_push_device() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 new.session_id := nullif(auth.jwt()->>'session_id','')::uuid;
 new.updated_at := clock_timestamp();
 return new;
end $$;
revoke all on function private.stamp_driver_push_device() from public,anon,authenticated;
create trigger stamp_driver_push_device before insert or update on public.driver_push_devices for each row execute function private.stamp_driver_push_device();

create table private.driver_push_config (
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 project_url text,
 secret_id uuid,
 secret_hash text
);
insert into private.driver_push_config(id) values(true);
create table private.driver_push_outbox (
 notification_id uuid primary key references public.notifications(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 job_id uuid not null references public.jobs(id) on delete cascade,
 created_at timestamptz not null default now(),
 attempts integer not null default 0,
 available_at timestamptz not null default now(),
 locked_until timestamptz,
 completed_at timestamptz,
 result text check(result in ('sent','skipped','retry'))
);
create index driver_push_outbox_pending_idx on private.driver_push_outbox(available_at) where completed_at is null;
alter table private.driver_push_outbox enable row level security;
alter table private.driver_push_config enable row level security;
revoke all on private.driver_push_outbox,private.driver_push_config from public,anon,authenticated;
grant usage on schema private to service_role;
grant select,update,delete on private.driver_push_outbox to service_role;
grant select on private.driver_push_config to service_role;

-- Vault/pg_net are used only after explicit server activation. The core migration also runs offline.
create function private.wake_driver_push() returns void language plpgsql security definer set search_path='' as $$
declare settings private.driver_push_config; secret text;
begin
 select * into settings from private.driver_push_config where id;
 if not settings.enabled or settings.project_url is null or settings.secret_id is null then return; end if;
 if not exists(select 1 from private.driver_push_outbox where completed_at is null and attempts<5 and available_at<=now() and (locked_until is null or locked_until<now())) then return; end if;
 if not exists(select 1 from pg_extension where extname='pg_net') then return; end if;
 execute 'select decrypted_secret from vault.decrypted_secrets where id=$1' into secret using settings.secret_id;
 if secret is null then return; end if;
 execute 'select net.http_post(url:=$1,headers:=$2,body:=$3,timeout_milliseconds:=5000)'
 using settings.project_url||'/functions/v1/fletya-driver-push',
 jsonb_build_object('Content-Type','application/json','x-fletya-push-token',secret), '{}'::jsonb;
exception when others then
 -- Push infrastructure must never prevent creating/releasing a freight request.
 return;
end $$;
revoke all on function private.wake_driver_push() from public,anon,authenticated;
create function private.queue_driver_push() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.job_id is not null and exists(select 1 from public.profiles p where p.id=new.user_id and p.role='driver')
 and exists(select 1 from public.jobs j where j.id=new.job_id and j.status='requested' and j.driver_id is null) then
  insert into private.driver_push_outbox(notification_id,user_id,job_id) values(new.id,new.user_id,new.job_id) on conflict do nothing;
  perform private.wake_driver_push();
 end if;
 return new;
end $$;
revoke all on function private.queue_driver_push() from public,anon,authenticated;
create trigger queue_driver_push after insert on public.notifications for each row execute function private.queue_driver_push();

-- Narrow private projection avoids granting service_role direct reads of auth.sessions.
create function private.driver_push_session_active(p_session uuid,p_user uuid) returns boolean
 language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s where s.id=p_session and s.user_id=p_user and (s.not_after is null or s.not_after>now()));
$$;
revoke all on function private.driver_push_session_active(uuid,uuid) from public,anon,authenticated;
grant execute on function private.driver_push_session_active(uuid,uuid) to service_role;

-- Server-only RPCs. Invoker retains privilege boundaries; no authenticated/anon execution.
create function public.claim_driver_push_batch(p_secret text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare output jsonb;
begin
 if not exists(select 1 from private.driver_push_config where enabled
   and secret_hash=encode(sha256(convert_to(coalesce(p_secret,''),'UTF8')),'hex')) then
  raise insufficient_privilege using message='Invalid push authorization';
 end if;
 delete from private.driver_push_outbox where created_at<now()-interval '7 days';
 with candidates as (
  select notification_id from private.driver_push_outbox
  where completed_at is null and attempts<5 and available_at<=now()
   and (locked_until is null or locked_until<now())
  order by available_at,notification_id for update skip locked limit 10
 ), claimed as (
  update private.driver_push_outbox o set attempts=o.attempts+1,locked_until=now()+interval '90 seconds'
  from candidates c where o.notification_id=c.notification_id returning o.*
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'attempt',c.attempts,
  'devices',coalesce((select jsonb_agg(jsonb_build_object('installation_id',d.installation_id,'token',d.token,'registration_nonce',d.registration_nonce))
   from public.driver_push_devices d join public.profiles p on p.id=d.user_id and p.role='driver'
   where d.user_id=c.user_id and d.enabled
   and private.driver_push_session_active(d.session_id,d.user_id)
   and c.created_at>now()-interval '5 minutes'
   and exists(select 1 from public.jobs j where j.id=c.job_id and j.status='requested' and j.driver_id is null)
   and not exists(select 1 from public.jobs active where active.driver_id=c.user_id and active.status in ('en_route','picked_up'))),'[]'::jsonb)
 )),'[]'::jsonb) into output from claimed c;
 return output;
end $$;
create function public.finish_driver_push(p_notification_id uuid,p_attempt integer,p_result text,p_invalid_devices jsonb default '[]') returns void
 language plpgsql security invoker set search_path='' as $$
declare owner_id uuid;
begin
 if p_result not in ('sent','skipped','retry') then raise exception 'Invalid push outcome'; end if;
 update private.driver_push_outbox set result=p_result,
  completed_at=case when p_result='retry' and attempts<5 then null else now() end,
  locked_until=null,available_at=now()+interval '30 seconds'*greatest(1,attempts)
 where notification_id=p_notification_id and attempts=p_attempt and completed_at is null returning user_id into owner_id;
 if owner_id is not null then
  update public.driver_push_devices set enabled=false where user_id=owner_id and exists(select 1 from jsonb_array_elements(p_invalid_devices) invalid
   where installation_id=(invalid->>'installation_id')::uuid and token=invalid->>'token'
   and registration_nonce=(invalid->>'registration_nonce')::uuid);
 end if;
end $$;
-- Trigger normally derives session claims for user writes; server may only disable stale tokens.
create or replace function private.stamp_driver_push_device() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if current_user='service_role' then
  if tg_op<>'UPDATE' or new.enabled<>false or (to_jsonb(new)-'enabled') is distinct from (to_jsonb(old)-'enabled') then
   raise exception 'Server may only disable push devices';
  end if;
 else
  new.session_id := nullif(auth.jwt()->>'session_id','')::uuid;
  new.updated_at := clock_timestamp();
 end if;
 return new;
end $$;
revoke all on function public.claim_driver_push_batch(text),public.finish_driver_push(uuid,integer,text,jsonb) from public,anon,authenticated;
grant execute on function public.claim_driver_push_batch(text),public.finish_driver_push(uuid,integer,text,jsonb) to service_role;
notify pgrst,'reload schema';
