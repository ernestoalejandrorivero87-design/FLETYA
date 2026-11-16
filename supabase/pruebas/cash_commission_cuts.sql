-- Apply only in Pruebas, after cash payments and Stripe coexistence are enabled.
create table private.cash_collection_issues (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  reported_by uuid not null references public.profiles(id),
  reported_at timestamptz not null default now()
);
alter table private.cash_collection_issues enable row level security;
revoke all on private.cash_collection_issues from public, anon, authenticated;

create index jobs_cash_commission_cuts_idx on public.jobs (driver_id, cash_collected_at)
where payment_method = 'cash' and status = 'completed' and cash_collected_at is not null;

create function private.stamp_cash_delivery() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if old.status = 'picked_up' and new.status = 'completed' and new.payment_method = 'cash' then
    if current_user <> 'postgres' or auth.uid() is distinct from old.driver_id then
      raise insufficient_privilege using message = 'El fletero debe confirmar que recibió el efectivo para completar.';
    end if;
    -- This trigger runs after the guards that reject payment fields supplied by callers.
    new.cash_collected_at := clock_timestamp();
  end if;
  return new;
end $$;
revoke all on function private.stamp_cash_delivery() from public, anon, authenticated;
create trigger stamp_cash_delivery before update of status on public.jobs
for each row execute function private.stamp_cash_delivery();

create function private.complete_cash_delivery(p_job uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  job public.jobs;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='driver' and driver_status='approved') then
    raise insufficient_privilege;
  end if;
  select * into job from public.jobs where id=p_job and driver_id=actor and payment_method='cash' for update;
  if not found or job.status not in ('picked_up', 'completed') then
    raise invalid_parameter_value using message = 'La entrega en efectivo no está disponible.';
  end if;
  if job.status = 'picked_up' then
    update public.jobs set status='completed' where id=job.id returning * into job;
  elsif job.cash_collected_at is null then
    raise invalid_parameter_value using message = 'El servicio se cerró antes de habilitar la confirmación de efectivo.';
  end if;
  return to_jsonb(job);
end $$;

create function private.report_cash_collection_issue(p_job uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='driver' and driver_status='approved') then
    raise insufficient_privilege;
  end if;
  perform 1 from public.jobs where id=p_job and driver_id=actor and payment_method='cash' and status='picked_up' for update;
  if not found then raise invalid_parameter_value; end if;
  insert into private.cash_collection_issues(job_id, reported_by) values(p_job, actor) on conflict do nothing;
end $$;

create function private.cash_collection_issues_for_admin() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise insufficient_privilege; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'reported_at', i.reported_at) order by i.reported_at desc)
    from private.cash_collection_issues i join public.jobs j on j.id=i.job_id
    where j.status='picked_up'), '[]'::jsonb);
end $$;

create function private.cash_commission_cuts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  admin boolean := private.is_admin();
  local_today date := (now() at time zone 'America/Cancun')::date;
begin
  if not admin and (actor is null or not exists(select 1 from public.profiles where id=actor and role='driver' and driver_status='approved')) then
    raise insufficient_privilege;
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(cut) order by cut.week_start desc, cut.driver_id)
    from (
      select j.driver_id, date_trunc('week', j.cash_collected_at at time zone 'America/Cancun')::date as week_start,
        date_trunc('week', j.cash_collected_at at time zone 'America/Cancun')::date + 8 as due_on,
        local_today >= date_trunc('week', j.cash_collected_at at time zone 'America/Cancun')::date + 7 as closed,
        count(*) filter(where j.cash_commission_settled_at is null) as pending_count,
        coalesce(sum(round(j.price * 15)) filter(where j.cash_commission_settled_at is null), 0) as pending_cents,
        jsonb_agg(jsonb_build_object('id', j.id, 'date', (j.cash_collected_at at time zone 'America/Cancun')::date,
          'commission_cents', round(j.price * 15), 'settled', j.cash_commission_settled_at is not null)
          order by j.cash_collected_at, j.id) as jobs
      from public.jobs j
      where j.status='completed' and j.payment_method='cash' and j.cash_collected_at is not null
        and (admin or j.driver_id=actor)
      group by j.driver_id, 2
    ) cut
  ), '[]'::jsonb);
end $$;

create function private.settle_cash_commission_cut(p_driver uuid, p_week date, p_expected_cents bigint, p_expected_count integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  job_ids uuid[];
  actual_cents bigint;
  changed integer;
begin
  if not private.is_admin() then raise insufficient_privilege; end if;
  if p_driver is null or p_week is null or extract(isodow from p_week) <> 1
     or p_week + 7 > (now() at time zone 'America/Cancun')::date
     or p_expected_cents is null or p_expected_cents < 0 or p_expected_count is null or p_expected_count < 1 then
    raise invalid_parameter_value using message = 'Selecciona un corte cerrado y pendiente.';
  end if;
  select array_agg(item.id), sum(round(item.price * 15)) into job_ids, actual_cents
  from (
    select id, price from public.jobs where driver_id=p_driver and status='completed'
      and payment_method='cash' and cash_commission_settled_at is null
      and cash_collected_at >= p_week::timestamp at time zone 'America/Cancun'
      and cash_collected_at < (p_week + 7)::timestamp at time zone 'America/Cancun'
    order by id for update
  ) item;
  if cardinality(job_ids) is distinct from p_expected_count or actual_cents is distinct from p_expected_cents then
    raise invalid_parameter_value using message = 'El corte cambió. Actualiza y comprueba el importe antes de registrarlo.';
  end if;
  update public.jobs set cash_commission_settled_at = now() where id = any(job_ids);
  get diagnostics changed = row_count;
  return changed;
end $$;

create function public.complete_cash_delivery(p_job uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select private.complete_cash_delivery(p_job); $$;
create function public.report_cash_collection_issue(p_job uuid) returns void
language sql security invoker set search_path = '' as $$ select private.report_cash_collection_issue(p_job); $$;
create function public.cash_collection_issues_for_admin() returns jsonb
language sql security invoker set search_path = '' as $$ select private.cash_collection_issues_for_admin(); $$;
create function public.cash_commission_cuts() returns jsonb
language sql security invoker set search_path = '' as $$ select private.cash_commission_cuts(); $$;
create function public.settle_cash_commission_cut(p_driver uuid, p_week date, p_expected_cents bigint, p_expected_count integer)
returns integer language sql security invoker set search_path = '' as $$
  select private.settle_cash_commission_cut(p_driver, p_week, p_expected_cents, p_expected_count);
$$;

revoke execute on function public.record_cash_payment(uuid,text), private.record_cash_payment(uuid,text) from authenticated;
revoke all on function public.complete_cash_delivery(uuid), private.complete_cash_delivery(uuid),
  public.report_cash_collection_issue(uuid), private.report_cash_collection_issue(uuid),
  public.cash_collection_issues_for_admin(), private.cash_collection_issues_for_admin(),
  public.cash_commission_cuts(), private.cash_commission_cuts(),
  public.settle_cash_commission_cut(uuid,date,bigint,integer), private.settle_cash_commission_cut(uuid,date,bigint,integer)
from public, anon;
grant execute on function public.complete_cash_delivery(uuid), private.complete_cash_delivery(uuid),
  public.report_cash_collection_issue(uuid), private.report_cash_collection_issue(uuid),
  public.cash_collection_issues_for_admin(), private.cash_collection_issues_for_admin(),
  public.cash_commission_cuts(), private.cash_commission_cuts(),
  public.settle_cash_commission_cut(uuid,date,bigint,integer), private.settle_cash_commission_cut(uuid,date,bigint,integer)
to authenticated;

notify pgrst, 'reload schema';
