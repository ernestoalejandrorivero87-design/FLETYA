create table if not exists private.sandbox_card_driver_settlements_v1 (
 job_id uuid primary key references private.stripe_sandbox_orders(id),
 driver_id uuid not null,
 amount_cents bigint not null check(amount_cents >= 0),
 recorded_by uuid not null,
 recorded_at timestamptz not null default now()
);
alter table private.sandbox_card_driver_settlements_v1 enable row level security;
revoke all on private.sandbox_card_driver_settlements_v1 from public, anon, authenticated;