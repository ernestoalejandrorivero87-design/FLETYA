create table public.client_push_devices (
 user_id uuid not null references auth.users(id) on delete cascade,
 installation_id uuid not null,
 registration_nonce uuid not null,
 token text not null check (char_length(token) between 20 and 4096),
 session_id uuid not null,
 enabled boolean not null default true,
 updated_at timestamptz not null default now(),
 primary key(user_id,installation_id)
);
alter table public.client_push_devices enable row level security;
revoke all on public.client_push_devices from public,anon,authenticated;
grant select,delete on public.client_push_devices to authenticated;
grant insert(user_id,installation_id,registration_nonce,token,enabled),update(user_id,installation_id,registration_nonce,token,enabled) on public.client_push_devices to authenticated;
grant all on public.client_push_devices to service_role;
create policy client_owns_push_device on public.client_push_devices to authenticated
 using(user_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='client'))
 with check(user_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='client'));
create function private.stamp_client_push_device() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 new.session_id := nullif(auth.jwt()->>'session_id','')::uuid;
 new.updated_at := clock_timestamp();
 return new;
end $$;
revoke all on function private.stamp_client_push_device() from public,anon,authenticated;
create trigger stamp_client_push_device before insert or update on public.client_push_devices for each row execute function private.stamp_client_push_device();

-- Trigger normally derives session claims for user writes; server may only disable stale tokens.
create or replace function private.stamp_client_push_device() returns trigger language plpgsql security invoker set search_path='' as $$
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
create table private.client_push_outbox(
 sequence_id bigint generated always as identity unique,
 notification_id uuid primary key references public.notifications(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,job_id uuid not null references public.jobs(id) on delete cascade,
 event_type text not null,created_at timestamptz not null default clock_timestamp(),attempts integer not null default 0,
 available_at timestamptz not null default now(),locked_until timestamptz,completed_at timestamptz,
 result text check(result in ('sent','skipped','retry'))
);
create index client_push_pending on private.client_push_outbox(available_at) where completed_at is null;
alter table private.client_push_outbox enable row level security;
revoke all on private.client_push_outbox from public,anon,authenticated;
grant select,update,delete on private.client_push_outbox to service_role;
create function private.wake_client_push() returns void language plpgsql security definer set search_path='' as $$
declare settings private.driver_push_config;secret text;
begin
 select * into settings from private.driver_push_config where id;
 if not settings.enabled or settings.project_url is null or settings.secret_id is null then return;end if;
 if not exists(select 1 from private.client_push_outbox where completed_at is null and attempts<5 and available_at<=now() and (locked_until is null or locked_until<now())) then return;end if;
 if not exists(select 1 from pg_extension where extname='pg_net') then return;end if;
 execute 'select decrypted_secret from vault.decrypted_secrets where id=$1' into secret using settings.secret_id;
 if secret is null then return;end if;
 execute 'select net.http_post(url:=$1,headers:=$2,body:=$3,timeout_milliseconds:=5000)'
 using settings.project_url||'/functions/v1/fletya-client-push',jsonb_build_object('Content-Type','application/json','x-fletya-push-token',secret),'{}'::jsonb;
exception when others then return;end $$;
revoke all on function private.wake_client_push() from public,anon,authenticated;
create function private.queue_client_push() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.type in ('client_requested','client_assigned','client_arrived_pickup','client_picked_up','client_arrived_delivery','client_completed','client_cancelled','client_released')
 and new.job_id is not null and exists(select 1 from public.jobs j join public.profiles p on p.id=j.client_id and p.role='client' where j.id=new.job_id and j.client_id=new.user_id) then
  insert into private.client_push_outbox(notification_id,user_id,job_id,event_type) values(new.id,new.user_id,new.job_id,new.type) on conflict do nothing;
  perform private.wake_client_push();
 end if;
 return new;
end $$;
revoke all on function private.queue_client_push() from public,anon,authenticated;
create trigger queue_client_push after insert on public.notifications for each row execute function private.queue_client_push();
create function public.authorize_push_hook(p_secret text) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from private.driver_push_config where enabled and secret_hash=encode(sha256(convert_to(coalesce(p_secret,''),'UTF8')),'hex'));
$$;
revoke all on function public.authorize_push_hook(text) from public,anon,authenticated;
grant execute on function public.authorize_push_hook(text) to service_role;
create function public.claim_client_push_batch(p_secret text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare output jsonb;
begin
 if not public.authorize_push_hook(p_secret) then raise insufficient_privilege using message='Invalid push authorization';end if;
 delete from private.client_push_outbox where created_at<now()-interval '7 days';
 with candidates as(
  select notification_id from private.client_push_outbox where completed_at is null and attempts<5 and available_at<=now()
   and (locked_until is null or locked_until<now()) order by available_at,sequence_id for update skip locked limit 10
 ),claimed as(
  update private.client_push_outbox o set attempts=o.attempts+1,locked_until=now()+interval '90 seconds'
  from candidates c where o.notification_id=c.notification_id returning o.*
 )
 select coalesce(jsonb_agg(jsonb_build_object('notification_id',c.notification_id,'user_id',c.user_id,'job_id',c.job_id,'event_type',c.event_type,'attempt',c.attempts,
  'devices',coalesce((select jsonb_agg(jsonb_build_object('installation_id',d.installation_id,'token',d.token,'registration_nonce',d.registration_nonce))
   from public.client_push_devices d join public.profiles p on p.id=d.user_id and p.role='client'
   where d.user_id=c.user_id and d.enabled and private.driver_push_session_active(d.session_id,d.user_id)
   and c.created_at>now()-interval '10 minutes'
   and exists(select 1 from public.jobs j where j.id=c.job_id and j.client_id=c.user_id)
   and not exists(select 1 from private.client_push_outbox newer where newer.user_id=c.user_id and newer.job_id=c.job_id and newer.sequence_id>c.sequence_id)), '[]'::jsonb)
 )),'[]'::jsonb) into output from claimed c;return output;
end $$;
create function public.finish_client_push(p_notification_id uuid,p_attempt integer,p_result text,p_invalid_devices jsonb default '[]') returns void
 language plpgsql security invoker set search_path='' as $$
declare owner_id uuid;
begin
 if p_result not in ('sent','skipped','retry') then raise exception 'Invalid push outcome';end if;
 update private.client_push_outbox set result=p_result,completed_at=case when p_result='retry' and attempts<5 then null else now() end,
 locked_until=null,available_at=now()+interval '30 seconds'*greatest(1,attempts)
 where notification_id=p_notification_id and attempts=p_attempt and completed_at is null returning user_id into owner_id;
 if owner_id is not null then update public.client_push_devices set enabled=false where user_id=owner_id and exists(
  select 1 from jsonb_array_elements(p_invalid_devices) invalid where installation_id=(invalid->>'installation_id')::uuid
   and token=invalid->>'token' and registration_nonce=(invalid->>'registration_nonce')::uuid);end if;
end $$;
revoke all on function public.claim_client_push_batch(text),public.finish_client_push(uuid,integer,text,jsonb) from public,anon,authenticated;
grant execute on function public.claim_client_push_batch(text),public.finish_client_push(uuid,integer,text,jsonb) to service_role;
notify pgrst,'reload schema';
