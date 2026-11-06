-- Automatic WhatsApp receipt delivery. Financial records remain independent of
-- delivery: a payment is saved first, then exactly one durable outbox job is
-- created for it.

alter table public.customers
  add column if not exists whatsapp_receipt_opt_in boolean not null default false;

alter table public.payment_settings
  add column if not exists whatsapp_receipts_enabled boolean not null default false,
  add column if not exists whatsapp_template_name text,
  add column if not exists whatsapp_template_language text not null default 'en';

create table if not exists public.whatsapp_receipt_outbox (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  payment_id uuid not null unique references public.payments(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  recipient_phone text,
  status text not null default 'queued' check (status in (
    'queued', 'submitted', 'sent', 'delivered', 'read', 'failed', 'skipped'
  )),
  skip_reason text,
  provider_message_id text unique,
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz
);

create index if not exists whatsapp_receipt_outbox_pending_idx
  on public.whatsapp_receipt_outbox (status, next_attempt_at)
  where status in ('queued', 'failed');
create index if not exists whatsapp_receipt_outbox_company_idx
  on public.whatsapp_receipt_outbox (company_id, created_at desc);

alter table public.whatsapp_receipt_outbox enable row level security;

create policy "Company users can view WhatsApp receipt delivery"
  on public.whatsapp_receipt_outbox for select to authenticated
  using (company_id = public.current_company_id());

create or replace function public.queue_whatsapp_receipt_for_payment()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_enabled boolean := false;
  v_opted_in boolean := false;
  v_phone text;
  v_status text := 'skipped';
  v_reason text;
begin
  select coalesce(max(whatsapp_receipts_enabled), false)
    into v_enabled
  from public.payment_settings
  where company_id = new.company_id;

  select whatsapp_receipt_opt_in, phone
    into v_opted_in, v_phone
  from public.customers
  where id = new.customer_id and company_id = new.company_id;

  if not v_enabled then
    v_reason := 'Automatic WhatsApp receipts are disabled for this business.';
  elsif not coalesce(v_opted_in, false) then
    v_reason := 'Customer has not opted in to WhatsApp receipts.';
  elsif regexp_replace(coalesce(v_phone, ''), '[^0-9]', '', 'g') !~ '^[0-9]{10,15}$' then
    v_reason := 'Customer does not have a valid WhatsApp number.';
  else
    v_status := 'queued';
  end if;

  insert into public.whatsapp_receipt_outbox (
    company_id, payment_id, customer_id, recipient_phone, status, skip_reason
  ) values (
    new.company_id,
    new.id,
    new.customer_id,
    regexp_replace(coalesce(v_phone, ''), '[^0-9]', '', 'g'),
    v_status,
    v_reason
  ) on conflict (payment_id) do nothing;

  return new;
end;
$$;

drop trigger if exists payments_queue_whatsapp_receipt on public.payments;
create trigger payments_queue_whatsapp_receipt
after insert on public.payments
for each row execute function public.queue_whatsapp_receipt_for_payment();

revoke all on public.whatsapp_receipt_outbox from anon;
grant select on public.whatsapp_receipt_outbox to authenticated;
