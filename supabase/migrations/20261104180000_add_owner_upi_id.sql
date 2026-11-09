alter table public.payment_settings
  add column if not exists upi_id text;
