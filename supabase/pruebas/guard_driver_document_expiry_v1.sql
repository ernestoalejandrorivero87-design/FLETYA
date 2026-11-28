begin;
create function private.guard_driver_document_expiry_v1() returns trigger language plpgsql security definer set search_path='' as $$
begin
if new.driver_id is not null and (tg_op='INSERT' or new.driver_id is distinct from old.driver_id) then
 if exists(select 1 from jsonb_array_elements(private.driver_document_expiry_status_v1(new.driver_id)) d where (d->>'days_remaining')::integer<0) then
 raise exception 'Documentación vencida. Renueva tus documentos antes de aceptar otro servicio.' using errcode='42501';
 end if;
end if;
return new;
end $$;
revoke all on function private.guard_driver_document_expiry_v1() from public,anon,authenticated;
create trigger guard_driver_document_expiry_v1 before insert or update of driver_id on public.jobs for each row execute function private.guard_driver_document_expiry_v1();
commit;