CREATE OR REPLACE FUNCTION private.record_sandbox_card_settlement_v1(p_job uuid, p_expected_cents bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a private.stripe_sandbox_orders%rowtype; j public.jobs%rowtype; cents bigint; rec private.sandbox_card_driver_settlements_v1%rowtype;
begin
 if not private.is_admin() then raise insufficient_privilege; end if;
 select * into a from private.stripe_sandbox_orders where id=p_job for update;
 if not found or a.method is distinct from 'card' or a.card_state is distinct from 'paid' or (a.refund_state is not null and a.refund_state <> 'denied') then raise invalid_parameter_value; end if;
 select * into j from public.jobs where id=p_job for update;
 if not found or j.status is distinct from 'completed' or j.sandbox_card_state is distinct from 'paid' or j.sandbox_payment_method is distinct from 'card' or j.driver_id is null or j.test_driver_payout is null or j.test_driver_payout<0 or j.test_driver_payout>a.amount then raise invalid_parameter_value; end if;
 cents:=round(j.test_driver_payout*100);
 if cents is distinct from p_expected_cents then raise invalid_parameter_value; end if;
 insert into private.sandbox_card_driver_settlements_v1(job_id,driver_id,amount_cents,recorded_by) values(p_job,j.driver_id,cents,auth.uid()) returning * into rec;
 return to_jsonb(rec);
end $function$
;
CREATE OR REPLACE FUNCTION private.sandbox_card_settlement_status_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not private.is_admin() then raise insufficient_privilege; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('job_id',a.id,'eligible',a.card_state='paid' and (a.refund_state is null or a.refund_state='denied') and j.status='completed' and j.sandbox_card_state='paid' and j.driver_id is not null and j.test_driver_payout between 0 and a.amount,'settled_cents',s.amount_cents,'refund_state',a.refund_state)) from private.stripe_sandbox_orders a join public.jobs j on j.id=a.id left join private.sandbox_card_driver_settlements_v1 s on s.job_id=a.id where a.method='card'),'[]'::jsonb);
end $function$
;