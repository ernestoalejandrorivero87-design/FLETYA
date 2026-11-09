-- Keep the narrowly authorized privileged implementation outside the Data API schema.
alter function public.review_driver_application(uuid,boolean,text) set schema private;
create function public.review_driver_application(p_driver_id uuid,p_approved boolean,p_note text) returns jsonb
 language sql security invoker set search_path='' as $$
 select private.review_driver_application(p_driver_id,p_approved,p_note);
$$;
revoke all on function public.review_driver_application(uuid,boolean,text),private.review_driver_application(uuid,boolean,text) from public,anon;
grant execute on function public.review_driver_application(uuid,boolean,text),private.review_driver_application(uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
