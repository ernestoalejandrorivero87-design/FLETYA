begin;
create function private.register_driver_document_v1(p_type text,p_path text,p_expires date default null) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
if not private.owns_driver_document_path(p_path) then raise insufficient_privilege; end if;
if p_type is null or p_type not in ('portrait','license','vehicle','registration','mobility_permit') or split_part(p_path,'/',2)<>p_type then raise invalid_parameter_value; end if;
if p_type in ('license','registration','mobility_permit') and (p_expires is null or p_expires<current_date) then raise invalid_parameter_value using message='Indica una fecha de vigencia válida.'; end if;
if not exists(select 1 from storage.objects where bucket_id='driver-documents' and name=p_path) then raise invalid_parameter_value using message='Archivo no encontrado.'; end if;
perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_type,0));
insert into private.driver_document_reviews_v1(driver_id,document_type,object_path,expires_on,review_state) values(auth.uid(),p_type,p_path,p_expires,'in_review') returning id into v_id;
return v_id;
end $$;
create function public.register_driver_document_v1(p_type text,p_path text,p_expires date default null) returns uuid language sql security invoker set search_path='' as $$ select private.register_driver_document_v1(p_type,p_path,p_expires) $$;
revoke all on function private.register_driver_document_v1(text,text,date),public.register_driver_document_v1(text,text,date) from public,anon,authenticated;
grant execute on function private.register_driver_document_v1(text,text,date),public.register_driver_document_v1(text,text,date) to authenticated;
commit;