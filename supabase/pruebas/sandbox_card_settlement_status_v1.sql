create or replace function private.sandbox_card_settlement_status_v1() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise insufficient_privilege; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('job_id',a.id,'eligible',a.card_state='paid' and a.refund_state is null and j.status='completed' and j.sandbox_card_state='paid' and j.driver_id is not null and j.test_driver_payout between 0 and a.amount,'settled_cents',s.amount_cents,'refund_state',a.refund_state)) from private.stripe_sandbox_orders a join public.jobs j on j.id=a.id left join private.sandbox_card_driver_settlements_v1 s on s.job_id=a.id where a.method='card'),'[]'::jsonb);
end $$;
create or replace function public.sandbox_card_settlement_status_v1() returns jsonb language sql security invoker set search_path='' as $$ select private.sandbox_card_settlement_status_v1() $$;
revoke all on function private.sandbox_card_settlement_status_v1(),public.sandbox_card_settlement_status_v1() from public,anon,authenticated;
grant execute on function private.sandbox_card_settlement_status_v1(),public.sandbox_card_settlement_status_v1() to authenticated;