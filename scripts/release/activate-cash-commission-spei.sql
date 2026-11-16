-- Apply after the weekly cash commission functions.
create table if not exists private.cash_commission_spei_account (
  singleton boolean primary key default true check (singleton),
  bank text not null check (length(trim(bank)) between 1 and 80),
  beneficiary text not null check (length(trim(beneficiary)) between 1 and 120),
  clabe text not null check (clabe ~ '^[0-9]{18}$')
);
alter table private.cash_commission_spei_account enable row level security;
revoke all on private.cash_commission_spei_account from public, anon, authenticated;

create table private.cash_commission_spei_references (
  driver_id uuid not null references public.profiles(id),
  week_start date not null check (extract(isodow from week_start) = 1),
  reference integer generated always as identity (maxvalue 9999999),
  primary key (driver_id, week_start),
  unique (reference)
);
alter table private.cash_commission_spei_references enable row level security;
revoke all on private.cash_commission_spei_references from public, anon, authenticated;

create function private.assign_cash_commission_spei_reference() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.payment_method = 'cash' and new.status = 'completed'
     and new.cash_collected_at is not null and new.cash_collected_at is distinct from old.cash_collected_at then
    insert into private.cash_commission_spei_references (driver_id, week_start)
      values(new.driver_id, date_trunc('week', new.cash_collected_at at time zone 'America/Cancun')::date)
      on conflict (driver_id, week_start) do nothing;
  end if;
  return new;
end $$;
revoke all on function private.assign_cash_commission_spei_reference() from public, anon, authenticated;
create trigger assign_cash_commission_spei_reference after update on public.jobs
for each row execute function private.assign_cash_commission_spei_reference();

insert into private.cash_commission_spei_references (driver_id, week_start)
select distinct driver_id, date_trunc('week', cash_collected_at at time zone 'America/Cancun')::date
from public.jobs
where payment_method='cash' and status='completed' and cash_collected_at is not null and driver_id is not null
on conflict (driver_id, week_start) do nothing;

create function private.cash_commission_cuts_with_spei() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  cuts jsonb := private.cash_commission_cuts();
  account jsonb;
begin
  select jsonb_build_object('bank', bank, 'beneficiary', beneficiary, 'clabe', clabe)
    into account from private.cash_commission_spei_account where singleton;
  return coalesce((
    select jsonb_agg(cut || jsonb_build_object('spei_reference', ref.reference::text, 'spei_account',
      case when (cut->>'closed')::boolean and (cut->>'pending_count')::integer > 0 then account end)
      order by cut->>'week_start' desc, cut->>'driver_id')
    from jsonb_array_elements(cuts) cut
    left join private.cash_commission_spei_references ref
      on ref.driver_id=(cut->>'driver_id')::uuid and ref.week_start=(cut->>'week_start')::date
  ), '[]'::jsonb);
end $$;

create or replace function public.cash_commission_cuts() returns jsonb
language sql security invoker set search_path = '' as $$ select private.cash_commission_cuts_with_spei(); $$;
revoke all on function private.cash_commission_cuts_with_spei(), public.cash_commission_cuts() from public, anon;
grant execute on function private.cash_commission_cuts_with_spei(), public.cash_commission_cuts() to authenticated;

notify pgrst, 'reload schema';
