begin;
create function private.driver_documents_ready_v1(p_driver uuid) returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from public.profiles where id=p_driver and role='driver')
and not exists (
select 1 from unnest(array['portrait','license','vehicle','registration']) as required(kind)
where not exists (
select 1 from (select d.* from private.driver_document_reviews_v1 d where d.driver_id=p_driver and d.document_type=required.kind order by d.created_at desc,d.id desc limit 1) latest
where latest.review_state='approved' and (latest.expires_on is null or latest.expires_on>=current_date)
and exists(select 1 from storage.objects o where o.bucket_id='driver-documents' and o.name=latest.object_path)
));
$$;
revoke all on function private.driver_documents_ready_v1(uuid) from public,anon,authenticated;
create function private.guard_driver_document_approval_v1() returns trigger language plpgsql security definer set search_path='' as $$
begin
if new.role='driver' and new.driver_status='approved' and (old.driver_status is distinct from new.driver_status or old.role is distinct from new.role) and not private.driver_documents_ready_v1(new.id) then
raise insufficient_privilege using message='Completa y aprueba la documentación obligatoria antes de habilitar al fletero.';
end if;
return new;
end $$;
revoke all on function private.guard_driver_document_approval_v1() from public,anon,authenticated;
create trigger guard_driver_document_approval_v1 before update of driver_status,role on public.profiles for each row execute function private.guard_driver_document_approval_v1();
commit;