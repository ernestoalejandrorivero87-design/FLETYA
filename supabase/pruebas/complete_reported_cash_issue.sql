CREATE OR REPLACE FUNCTION private.report_cash_collection_issue(p_job uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
declare actor uuid := auth.uid();
begin
 if actor is null or not exists(select 1 from public.profiles where id=actor and role='driver' and driver_status='approved') then raise insufficient_privilege; end if;
 perform 1 from public.jobs where id=p_job and driver_id=actor and payment_method='cash' and cash_collected_at is null and status='picked_up' for update;
 if not found then
   if exists(select 1 from public.jobs j join private.cash_collection_issues i on i.job_id=j.id where j.id=p_job and j.driver_id=actor and j.status='completed' and j.payment_method='cash' and j.cash_collected_at is null and i.reported_by=actor and i.review_state in ('reported','reviewing','payment_required','closed_unpaid')) then return; end if;
   raise invalid_parameter_value;
 end if;
 insert into private.cash_collection_issues(job_id,reported_by) values(p_job,actor) on conflict do nothing;
 if not exists(select 1 from private.cash_collection_issues where job_id=p_job and review_state in ('reported','reviewing','payment_required','closed_unpaid')) then raise invalid_parameter_value; end if;
 perform private.complete_cash_delivery(p_job);
 if not exists(select 1 from public.jobs where id=p_job and status='completed' and cash_collected_at is null) then raise exception 'No se pudo cerrar el servicio sin cobro'; end if;
end $function$;