-- Activate ONLY after FIREBASE_SERVICE_ACCOUNT_JSON has been saved in Edge Function secrets.
-- Set the target in the same SQL transaction before this script, for example:
-- select set_config('fletya.push_project_url','https://<project-ref>.supabase.co',false);
-- This script generates the internal webhook token inside Vault and never prints it.
create extension if not exists pg_net;
create extension if not exists pg_cron;
revoke execute on all functions in schema net from public,anon,authenticated;
revoke execute on all functions in schema cron from public,anon,authenticated;
do $$
declare target_url text:=current_setting('fletya.push_project_url',true); hook_id uuid; hook_value text;
begin
 if target_url is null or target_url !~ '^https://[a-z]{20}\.supabase\.co$' then
  raise exception 'Set the correct Supabase project URL first';
 end if;
 select id,decrypted_secret into hook_id,hook_value from vault.decrypted_secrets where name='fletya_driver_push_hook';
 if hook_id is null then
  hook_value:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  select vault.create_secret(hook_value,'fletya_driver_push_hook','Internal driver-push dispatcher authentication') into hook_id;
 end if;
 update private.driver_push_config set enabled=true,project_url=target_url,secret_id=hook_id,
  secret_hash=encode(sha256(convert_to(hook_value,'UTF8')),'hex') where id;
 perform cron.schedule('fletya-driver-push','* * * * *','select private.wake_driver_push();');
 perform private.wake_driver_push();
end $$;
