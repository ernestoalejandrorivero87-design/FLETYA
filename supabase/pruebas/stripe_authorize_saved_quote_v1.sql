CREATE OR REPLACE FUNCTION public.stripe_sandbox_card(p_action text, p_id uuid, p_actor uuid DEFAULT NULL::uuid, p_intent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  attempt private.stripe_sandbox_orders;
  job public.jobs;
begin
  select * into attempt from private.stripe_sandbox_orders where id=p_id and method='card';
  if not found then return null; end if;
  if p_action in ('claim','resume') then
    if not exists(select 1 from public.profiles where id=p_actor and role='driver' and driver_status='approved') then
      return null;
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-card-driver:' || p_actor::text,0));
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('fletya-route-order:' || attempt.client_id::text,0));
  select * into attempt from private.stripe_sandbox_orders where id=p_id;
  select * into job from public.jobs where id=p_id for update;

  if p_action='authorize' then
    if attempt.client_id is distinct from p_actor or attempt.stripe_session is null
       or p_intent is null or p_intent !~ '^pi_[A-Za-z0-9]+$' then return null; end if;
    if attempt.card_state is null and attempt.state='pending' then
      if job.id is not null or exists(select 1 from public.jobs
         where route_quote_id=attempt.quote_id or (client_id=attempt.client_id
         and status in ('requested','accepted','en_route','picked_up'))) or attempt.expires_at <= now() or exists(select 1 from private.cash_collection_issues i join public.jobs j on j.id=i.job_id where j.client_id=attempt.client_id and j.cash_collected_at is null and i.review_state in ('reported','reviewing','payment_required','closed_unpaid')) then
        update private.stripe_sandbox_orders set card_intent=p_intent,card_state='releasing'
          where id=p_id returning * into attempt;
      else
        insert into public.jobs(id,client_id,origin,destination,distance_km,vehicle_type,helpers,service_type,
          price,route_quote_id,test_driver_payout,sandbox_payment_method,sandbox_card_state,description)
        values(p_id,attempt.client_id,attempt.origin,attempt.destination,attempt.distance_km,attempt.vehicle,
          attempt.helpers,attempt.service,attempt.amount,
          (select id from public.fletya_route_quotes where id=attempt.quote_id and erase_at>now()),
          case when attempt.saved_quote_id is not null then attempt.quoted_driver_payout when attempt.vehicle='pickup' then attempt.amount-round(attempt.amount*0.15,2) end,'card','held',attempt.cargo_description)
        returning * into job;
        if attempt.saved_quote_id is not null then
          update private.vehicle_cargo_quote_snapshots_v1 set confirmed_job_id=p_id where id=attempt.saved_quote_id;
        end if;
        update private.stripe_sandbox_orders set state='booked',card_intent=p_intent,card_state='held',
          hold_until=now()+interval '15 minutes' where id=p_id returning * into attempt;
      end if;
    end if;
  elsif p_action='claim' then
    if job.driver_id=p_actor and attempt.card_state in ('capturing','paid') then
      return jsonb_build_object('order',to_jsonb(attempt),'job',to_jsonb(job));
    end if;
    if attempt.card_state is distinct from 'held' or attempt.hold_until <= now()
       or job.status is distinct from 'requested' or job.driver_id is not null
       or exists(select 1 from public.jobs where driver_id=p_actor and status in ('accepted','en_route','picked_up')) then
      return null;
    end if;
    update public.jobs set status='accepted',driver_id=p_actor,sandbox_card_state='capturing'
      where id=p_id returning * into job;
    update private.stripe_sandbox_orders set card_state='capturing' where id=p_id returning * into attempt;
  elsif p_action='resume' then
    if job.driver_id is distinct from p_actor or attempt.card_state is distinct from 'capturing' then return null; end if;
  elsif p_action in ('sweep','cancel') then
    if p_action='cancel' and attempt.client_id is distinct from p_actor then return null; end if;
    if attempt.card_state='held' and (p_action='cancel' or attempt.hold_until <= now()) then
      update public.jobs set status='cancelled' where id=p_id returning * into job;
      update private.stripe_sandbox_orders set card_state='releasing' where id=p_id returning * into attempt;
    end if;
    if p_action='cancel' and attempt.card_state not in ('releasing','released') then return null; end if;
  elsif p_action='captured' then
    if attempt.card_intent is distinct from p_intent then return null; end if;
    if attempt.card_state='capturing' then
      update public.jobs set status='en_route',sandbox_card_state='paid' where id=p_id returning * into job;
      update private.stripe_sandbox_orders set card_state='paid' where id=p_id returning * into attempt;
    end if;
  elsif p_action='released' then
    if attempt.card_intent is distinct from p_intent then return null; end if;
    if attempt.card_state in ('releasing','capturing') then
      update public.jobs set status='cancelled',driver_id=null,sandbox_card_state='released'
        where id=p_id returning * into job;
      update private.stripe_sandbox_orders set state=case when job.id is null then 'expired' else 'booked' end,
        card_state='released' where id=p_id returning * into attempt;
    end if;
  else
    return null;
  end if;
  return jsonb_build_object('order',to_jsonb(attempt),'job',to_jsonb(job));
end $function$
;