begin;
create function private.review_driver_document_v1(p_id uuid,p_approved boolean,p_note text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare d private.driver_document_reviews_v1%rowtype;
begin
if auth.uid() is null or not private.is_admin() then raise insufficient_privilege; end if;
if p_approved is null or (not p_approved and coalesce(char_length(btrim(p_note)),0)<5) or coalesce(char_length(p_note),0)>500 then raise invalid_parameter_value using message='Indica un motivo válido de rechazo.'; end if;
select * into d from private.driver_document_reviews_v1 where id=p_id for update;
if not found or d.review_state<>'in_review' then raise invalid_parameter_value using message='Documento no disponible para revisión.'; end if;
if p_approved and d.expires_on<current_date then raise invalid_parameter_value using message='Documento vencido.'; end if;
if p_approved and not exists(select 1 from storage.objects where bucket_id='driver-documents' and name=d.object_path) then raise invalid_parameter_value using message='Archivo no encontrado.'; end if;
update private.driver_document_reviews_v1 set review_state=case when p_approved then 'approved' else 'rejected' end,review_note=nullif(btrim(p_note),''),reviewed_by=auth.uid(),reviewed_at=now() where id=p_id;
return p_id;
end $$;
create function public.review_driver_document_v1(p_id uuid,p_approved boolean,p_note text default null) returns uuid language sql security invoker set search_path='' as $$ select private.review_driver_document_v1(p_id,p_approved,p_note) $$;
revoke all on function private.review_driver_document_v1(uuid,boolean,text),public.review_driver_document_v1(uuid,boolean,text) from public,anon,authenticated;
grant execute on function private.review_driver_document_v1(uuid,boolean,text),public.review_driver_document_v1(uuid,boolean,text) to authenticated;
commit;