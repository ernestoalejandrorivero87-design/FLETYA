-- Pruebas only. Apply after scripts/release/activate-cash-payments.sql.
create function private.guard_cash_stripe_checkout() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.payment_method is distinct from 'cash' then
    return new;
  end if;

  -- Cash booking holds the same per-client lock as Stripe reservation.
  if exists (
    select 1 from private.stripe_sandbox_orders
    where client_id = new.client_id and state in ('pending', 'review')
  ) then
    raise invalid_parameter_value using message = 'Tienes un pago de prueba pendiente o en revisión.';
  end if;
  return new;
end $$;

revoke all on function private.guard_cash_stripe_checkout() from public, anon, authenticated;
create trigger guard_cash_stripe_checkout before insert on public.jobs
for each row execute function private.guard_cash_stripe_checkout();
