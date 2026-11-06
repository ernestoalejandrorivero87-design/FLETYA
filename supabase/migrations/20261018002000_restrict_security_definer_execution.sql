-- Reduce direct API execution of SECURITY DEFINER helpers.
-- Draft only: validate trigger behavior in staging before production.
-- is_admin() must remain executable by authenticated users because RLS policies call it.
revoke all on function public.is_admin() from public;
revoke all on function public.is_admin() from anon;
grant execute on function public.is_admin() to authenticated;

-- These functions are designed to run as database triggers, not as client RPC calls.
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;

revoke all on function public.notify_drivers_new_job() from public;
revoke all on function public.notify_drivers_new_job() from anon;
revoke all on function public.notify_drivers_new_job() from authenticated;
