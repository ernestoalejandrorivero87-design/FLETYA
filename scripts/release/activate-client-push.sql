-- Production dispatch only, after the client sender is deployed and tested.
-- Reuses the private hook authorization already held in Vault; never prints its value.
do $$begin
 if not exists(select 1 from private.driver_push_config where enabled and secret_id is not null and project_url is not null) then raise exception 'Configure the private push hook first';end if;
 if not exists(select 1 from pg_extension where extname='pg_cron') then raise exception 'Existing pg_cron dispatcher is required';end if;
end $$;
select cron.schedule('fletya-client-push','* * * * *','select private.wake_client_push();');
