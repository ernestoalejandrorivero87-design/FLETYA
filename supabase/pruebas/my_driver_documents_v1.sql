begin;
create function private.my_driver_documents_v1() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='driver') then raise insufficient_privilege; end if;
return coalesce((select jsonb_agg(to_jsonb(d) order by d.document_type) from (select distinct on (document_type) id,document_type,object_path,review_state,expires_on,review_note,created_at from private.driver_document_reviews_v1 where driver_id=auth.uid() order by document_type,created_at desc,id desc) d),'[]'::jsonb);
end $$;
create function public.my_driver_documents_v1() returns jsonb language sql stable security invoker set search_path='' as $$ select private.my_driver_documents_v1() $$;
revoke all on function private.my_driver_documents_v1(),public.my_driver_documents_v1() from public,anon,authenticated;
grant execute on function private.my_driver_documents_v1(),public.my_driver_documents_v1() to authenticated;
commit;