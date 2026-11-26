CREATE OR REPLACE FUNCTION public.stripe_reserve_saved_quote_v1(p_client uuid, p_id uuid, p_saved_quote uuid, p_description text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s private.vehicle_cargo_quote_snapshots_v1%rowtype; r public.fletya_route_quotes%rowtype; a private.stripe_sandbox_orders%rowtype;
begin
 if p_id is null or p_saved_quote is null or length(trim(coalesce(p_description,'')))<3 or length(p_description)>1500 or not exists(select 1 from public.profiles where id=p_client and role='client') then raise invalid_parameter_value; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:'||p_client::text,0));
 if exists(select 1 from private.cash_collection_issues i join public.jobs j on j.id=i.job_id where j.client_id=p_client and j.cash_collected_at is null and i.review_state in ('reported','reviewing','payment_required','closed_unpaid')) then raise exception using errcode='P0001',message='Tienes una incidencia de pago pendiente. Regularízala antes de solicitar otro flete.'; end if;
 select * into a from private.stripe_sandbox_orders where id=p_id;
 if found then
  if a.client_id is distinct from p_client or a.saved_quote_id is distinct from p_saved_quote or a.cargo_description is distinct from trim(p_description) or a.amount is distinct from p_amount or a.method is distinct from 'card' then raise invalid_parameter_value; end if;
  return to_jsonb(a);
 end if;
 select * into s from private.vehicle_cargo_quote_snapshots_v1 where id=p_saved_quote and client_id=p_client for update;
 if not found or s.expires_at<=now() or s.confirmed_job_id is not null or s.total is distinct from p_amount then raise invalid_parameter_value using message='Cotización no disponible o importe incorrecto.'; end if;
 select * into r from public.fletya_route_quotes where id=s.route_quote_id and client_id=p_client and expires_at>now() for update;
 if not found then raise invalid_parameter_value; end if;
 if exists(select 1 from public.jobs where id=p_id or route_quote_id=r.id or (client_id=p_client and status in ('requested','accepted','en_route','picked_up'))) then raise unique_violation; end if;
 if exists(select 1 from private.stripe_sandbox_orders where client_id=p_client and state in ('pending','review')) then raise unique_violation; end if;
 insert into private.stripe_sandbox_orders(id,client_id,quote_id,origin,destination,distance_km,vehicle,helpers,service,amount,method,saved_quote_id,cargo_description,quoted_driver_payout)
 values(p_id,p_client,r.id,r.origin,r.destination,r.distance_km,s.vehicle_code,s.helpers,s.category,s.total,'card',s.id,trim(p_description),(s.price_breakdown->>'driver_gross')::numeric) returning * into a;
 return to_jsonb(a);
end $function$
;
revoke all on function public.stripe_reserve_saved_quote_v1(uuid,uuid,uuid,text,numeric) from public,anon,authenticated;
grant execute on function public.stripe_reserve_saved_quote_v1(uuid,uuid,uuid,text,numeric) to service_role;