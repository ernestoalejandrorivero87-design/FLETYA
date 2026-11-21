create policy "classified_vehicle_offer_visibility_v2" on public.jobs
as restrictive for select to authenticated
using (
  status <> 'requested'
  or driver_id is not null
  or vehicle_type is null
  or vehicle_type not in ('pickup','estaquita_abierta','estaquita_caja_seca','camion_3_5t')
  or client_id = (select auth.uid())
  or private.is_admin()
  or exists (
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.role='driver' and p.driver_status='approved'
    and private.vehicle_request_matches_v2(jobs.vehicle_type,p.vehicle_type)
  )
);