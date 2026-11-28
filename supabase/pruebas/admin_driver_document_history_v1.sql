begin;
create function private.admin_driver_document_history_v1(p_driver uuid,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
if auth.uid() is null or not private.is_admin() then raise insufficient_privilege; end if;
if p_offset is null or p_offset<0 then raise invalid_parameter_value; end if;
return coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc,d.id desc) from (select id,document_type,object_path,review_state,expires_on,review_note,created_at,reviewed_at from private.driver_document_reviews_v1 where driver_id=p_driver order by created_at desc,id desc limit 21 offset p_offset) d),'[]'::jsonb);
end $$;
create function public.admin_driver_document_history_v1(p_driver uuid,p_offset integer default 0) returns jsonb language sql stable security invoker set search_path='' as $$ select private.admin_driver_document_history_v1(p_driver,p_offset) $$;
revoke all on function private.admin_driver_document_history_v1(uuid,integer),public.admin_driver_document_history_v1(uuid,integer) from public,anon,authenticated;
grant execute on function private.admin_driver_document_history_v1(uuid,integer),public.admin_driver_document_history_v1(uuid,integer) to authenticated;
commit;