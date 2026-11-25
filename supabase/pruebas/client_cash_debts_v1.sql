-- PRUEBAS only: authenticated client can read only their own unresolved debts.
begin;
create or replace function private.client_cash_debts_v1() returns jsonb language sql stable security definer set search_path='' as $$
select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'amount',j.price,'state',i.review_state,'payment_due_at',i.payment_due_at) order by i.reported_at desc),'[]'::jsonb)
from private.cash_collection_issues i join public.jobs j on j.id=i.job_id
where auth.uid() is not null and j.client_id=auth.uid() and j.cash_collected_at is null and i.review_state in ('reported','reviewing','payment_required','closed_unpaid');
$$;
revoke all on function private.client_cash_debts_v1() from public,anon;
grant execute on function private.client_cash_debts_v1() to authenticated;
create or replace function public.client_cash_debts_v1() returns jsonb language sql stable security invoker set search_path='' as $$ select private.client_cash_debts_v1(); $$;
revoke all on function public.client_cash_debts_v1() from public,anon;
grant execute on function public.client_cash_debts_v1() to authenticated;
commit;