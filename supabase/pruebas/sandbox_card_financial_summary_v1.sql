create or replace function private.sandbox_card_financial_summary_v1() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise insufficient_privilege; end if;
 return (select jsonb_build_object(
 'captured_cents',coalesce(sum(round(a.amount*100)) filter(where a.card_state='paid'),0),
 'refunded_cents',coalesce(sum(round(a.amount*100)) filter(where a.card_state='paid' and a.refund_state='confirmed'),0),
 'settled_cents',coalesce(sum(s.amount_cents),0),
 'settled_refund_review_cents',coalesce(sum(s.amount_cents) filter(where a.refund_state='confirmed'),0),
 'settled_refund_review_count',count(*) filter(where a.refund_state='confirmed' and s.job_id is not null)
 ) from private.stripe_sandbox_orders a left join private.sandbox_card_driver_settlements_v1 s on s.job_id=a.id where a.method='card');
end $$;
create or replace function public.sandbox_card_financial_summary_v1() returns jsonb language sql security invoker set search_path='' as $$ select private.sandbox_card_financial_summary_v1() $$;
revoke all on function private.sandbox_card_financial_summary_v1(),public.sandbox_card_financial_summary_v1() from public,anon,authenticated;
grant execute on function private.sandbox_card_financial_summary_v1(),public.sandbox_card_financial_summary_v1() to authenticated;