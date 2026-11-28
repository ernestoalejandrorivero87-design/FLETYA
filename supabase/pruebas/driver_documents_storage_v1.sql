begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values ('driver-documents','driver-documents',false,10485760,array['image/jpeg','image/png','application/pdf']);
create function private.owns_driver_document_path(p_name text) returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and split_part(p_name,'/',1)=auth.uid()::text and exists(select 1 from public.profiles where id=auth.uid() and role='driver') $$;
revoke all on function private.owns_driver_document_path(text) from public,anon;
grant execute on function private.owns_driver_document_path(text) to authenticated;
create policy driver_documents_read on storage.objects for select to authenticated using (bucket_id='driver-documents' and (private.is_admin() or private.owns_driver_document_path(name)));
create policy driver_documents_upload on storage.objects for insert to authenticated with check (bucket_id='driver-documents' and private.owns_driver_document_path(name) and name ~ '^[0-9a-f-]{36}/(portrait|license|vehicle|registration|mobility_permit)/[0-9a-f-]{36}\.(jpg|png|pdf)$');
commit;