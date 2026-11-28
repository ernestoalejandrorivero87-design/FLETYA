begin;
create function private.admin_driver_documents_v1(p_driver uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
if auth.uid() is null or not private.is_admin() then raise insufficient_privilege; end if;
return coalesce((select jsonb_agg(to_jsonb(d) order by d.document_type) from (select distinct on (document_type) id,driver_id,document_type,object_path,review_state,expires_on,review_note,created_at,reviewed_at from private.driver_document_reviews_v1 where driver_id=p_driver order by document_type,created_at desc,id desc) d),'[]'::jsonb);
end $$;
create function public.admin_driver_documents_v1(p_driver uuid) returns jsonb language sql stable security invoker set search_path='' as $$ select private.admin_driver_documents_v1(p_driver) $$;
revoke all on function private.admin_driver_documents_v1(uuid),public.admin_driver_documents_v1(uuid) from public,anon,authenticated;
grant execute on function private.admin_driver_documents_v1(uuid),public.admin_driver_documents_v1(uuid) to authenticated;
commit;