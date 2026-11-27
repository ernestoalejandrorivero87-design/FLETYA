create or replace function private.record_sandbox_card_settlement_v1(p_job uuid,p_expected_cents bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare a private.stripe_sandbox_orders%rowtype; j public.jobs%rowtype; cents bigint; rec private.sandbox_card_driver_settlements_v1%rowtype;
begin
 if not private.is_admin() then raise insufficient_privilege; end if;
 select * into a from private.stripe_sandbox_orders where id=p_job for update;
 if not found or a.method is distinct from 'card' or a.card_state is distinct from 'paid' or a.refund_state is not null then raise invalid_parameter_value; end if;
 select * into j from public.jobs where id=p_job for update;
 if not found or j.status is distinct from 'completed' or j.sandbox_card_state is distinct from 'paid' or j.sandbox_payment_method is distinct from 'card' or j.driver_id is null or j.test_driver_payout is null or j.test_driver_payout<0 or j.test_driver_payout>a.amount then raise invalid_parameter_value; end if;
 cents:=round(j.test_driver_payout*100);
 if cents is distinct from p_expected_cents then raise invalid_parameter_value; end if;
 insert into private.sandbox_card_driver_settlements_v1(job_id,driver_id,amount_cents,recorded_by) values(p_job,j.driver_id,cents,auth.uid()) returning * into rec;
 return to_jsonb(rec);
end $$;
create or replace function public.record_sandbox_card_settlement_v1(p_job uuid,p_expected_cents bigint) returns jsonb language sql security invoker set search_path='' as $$ select private.record_sandbox_card_settlement_v1(p_job,p_expected_cents) $$;
revoke all on function private.record_sandbox_card_settlement_v1(uuid,bigint),public.record_sandbox_card_settlement_v1(uuid,bigint) from public,anon,authenticated;
grant execute on function private.record_sandbox_card_settlement_v1(uuid,bigint),public.record_sandbox_card_settlement_v1(uuid,bigint) to authenticated;