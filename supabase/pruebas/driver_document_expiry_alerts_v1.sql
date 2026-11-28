begin;
create function private.driver_document_expiry_status_v1(p_driver uuid) returns jsonb language sql stable security definer set search_path='' as $$
select coalesce(jsonb_agg(jsonb_build_object('document_type',d.document_type,'expires_on',d.expires_on,'days_remaining',d.expires_on-(now() at time zone 'America/Cancun')::date,'review_state',d.review_state) order by d.expires_on),'[]'::jsonb)
from (select distinct on(document_type) document_type,expires_on,review_state from private.driver_document_reviews_v1 where driver_id=p_driver and review_state='approved' order by document_type,created_at desc,id desc) d
where d.expires_on is not null and d.expires_on <= (now() at time zone 'America/Cancun')::date+30;
$$;
revoke all on function private.driver_document_expiry_status_v1(uuid) from public,anon,authenticated;
create function private.admin_driver_expiry_alerts_v1() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
if auth.uid() is null or not private.is_admin() then raise insufficient_privilege; end if;
return coalesce((select jsonb_agg(jsonb_build_object('driver_id',p.id,'full_name',p.full_name,'documents',x.docs)) from public.profiles p cross join lateral (select private.driver_document_expiry_status_v1(p.id) docs) x where p.role='driver' and p.driver_status='approved' and jsonb_array_length(x.docs)>0),'[]'::jsonb);
end $$;
create function public.admin_driver_expiry_alerts_v1() returns jsonb language sql stable security invoker set search_path='' as $$ select private.admin_driver_expiry_alerts_v1() $$;
revoke all on function private.admin_driver_expiry_alerts_v1(),public.admin_driver_expiry_alerts_v1() from public,anon,authenticated;
grant execute on function private.admin_driver_expiry_alerts_v1(),public.admin_driver_expiry_alerts_v1() to authenticated;
commit;