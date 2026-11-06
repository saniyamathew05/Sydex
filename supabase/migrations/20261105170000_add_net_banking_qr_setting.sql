alter table public.payment_settings
  add column if not exists net_banking_qr text not null default '';
