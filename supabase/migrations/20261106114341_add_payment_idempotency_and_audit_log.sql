-- Financial safety baseline: an idempotent payment RPC and a database-owned,
-- append-only audit record. This migration does not alter existing balances.

alter table public.payments
  add column if not exists idempotency_key text;

create unique index if not exists payments_company_idempotency_key_uidx
  on public.payments (company_id, idempotency_key)
  where idempotency_key is not null;

create table if not exists public.financial_audit_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  actor_id uuid,
  event_type text not null,
  target_table text not null,
  target_id uuid,
  occurred_at timestamptz not null default now(),
  previous_values jsonb,
  new_values jsonb,
  request_id text,
  check (event_type in (
    'payment_created', 'payment_updated', 'payment_deleted',
    'ledger_entry_created', 'ledger_entry_updated', 'ledger_entry_deleted'
  ))
);

create index if not exists financial_audit_log_company_time_idx
  on public.financial_audit_log (company_id, occurred_at desc);
create index if not exists financial_audit_log_target_idx
  on public.financial_audit_log (target_table, target_id);

alter table public.financial_audit_log enable row level security;

-- Audit entries are written only by database triggers. Owners may read only the
-- events for their active company; no client can insert, alter, or delete them.
drop policy if exists "Owners can read company financial audit" on public.financial_audit_log;
create policy "Owners can read company financial audit"
  on public.financial_audit_log
  for select
  to authenticated
  using (
    company_id = (select public.current_company_id())
    and (select public.get_my_role()) = 'owner'
  );

create or replace function public.write_financial_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_target_id uuid;
  v_event_type text;
  v_previous jsonb;
  v_new jsonb;
  v_request_id text;
begin
  if tg_op = 'DELETE' then
    v_company_id := old.company_id;
    v_target_id := old.id;
    v_previous := to_jsonb(old);
    v_new := null;
  else
    v_company_id := new.company_id;
    v_target_id := new.id;
    v_previous := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
    v_new := to_jsonb(new);
  end if;

  if tg_table_name = 'payments' then
    v_event_type := case tg_op
      when 'INSERT' then 'payment_created'
      when 'UPDATE' then 'payment_updated'
      else 'payment_deleted'
    end;
    if tg_op = 'DELETE' then
      v_request_id := old.idempotency_key;
    else
      v_request_id := new.idempotency_key;
    end if;
  else
    v_event_type := case tg_op
      when 'INSERT' then 'ledger_entry_created'
      when 'UPDATE' then 'ledger_entry_updated'
      else 'ledger_entry_deleted'
    end;
    v_request_id := null;
  end if;

  insert into public.financial_audit_log (
    company_id, actor_id, event_type, target_table, target_id,
    previous_values, new_values, request_id
  ) values (
    v_company_id, auth.uid(), v_event_type, tg_table_name, v_target_id,
    v_previous, v_new, v_request_id
  );
  return coalesce(new, old);
end;
$$;

revoke all on function public.write_financial_audit_log() from public, anon, authenticated;

drop trigger if exists payments_financial_audit on public.payments;
create trigger payments_financial_audit
  after insert or update or delete on public.payments
  for each row execute function public.write_financial_audit_log();

drop trigger if exists ledger_entries_financial_audit on public.ledger_entries;
create trigger ledger_entries_financial_audit
  after insert or update or delete on public.ledger_entries
  for each row execute function public.write_financial_audit_log();

create or replace function public.record_payment_idempotent(
  p_customer_id uuid,
  p_amount numeric,
  p_discount numeric default 0,
  p_notes text default null,
  p_signature_path text default null,
  p_transaction_date timestamptz default now(),
  p_payment_method text default 'cash',
  p_payment_method_note text default null,
  p_entered_at timestamptz default now(),
  p_idempotency_key text default null
)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text := public.get_my_role();
  v_company_id uuid := public.current_company_id();
  v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2);
  v_discount numeric(12,2) := round(coalesce(p_discount, 0), 2);
  v_amount_received numeric(12,2);
  v_remaining_balance numeric(12,2);
  v_payment public.payments%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be logged in.';
  end if;
  if v_role not in ('owner', 'salesman') then
    raise exception 'You are not allowed to record payments.';
  end if;
  if v_company_id is null then
    raise exception 'Your account is not linked to a company.';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 16 or length(p_idempotency_key) > 128 then
    raise exception 'A valid payment request key is required.';
  end if;

  select * into v_payment
  from public.payments
  where company_id = v_company_id
    and idempotency_key = trim(p_idempotency_key);
  if found then
    return v_payment;
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount to settle must be greater than zero.';
  end if;
  if p_payment_method not in ('cash', 'cheque', 'neft', 'gpay') then
    raise exception 'Invalid payment method.';
  end if;
  if v_discount < 0 or v_discount >= p_amount then
    raise exception 'Discount must be less than the amount being settled.';
  end if;
  v_amount_received := round(p_amount - v_discount, 2);
  if v_amount_received <= 0 then
    raise exception 'Amount actually received must be greater than zero.';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id
    and is_active = true
    and company_id = v_company_id
  for update;
  if not found then
    raise exception 'Customer was not found or is inactive.';
  end if;

  select round(
    v_customer.opening_balance + coalesce(sum(case
      when entry_type in ('purchase', 'sale', 'bounced_check') then amount
      when entry_type in ('payment', 'return', 'sales_return') then -amount
      else 0
    end), 0), 2)
  into v_previous_balance
  from public.ledger_entries
  where customer_id = p_customer_id
    and (company_id = v_company_id or company_id is null);

  v_remaining_balance := round(v_previous_balance - p_amount, 2);

  begin
    insert into public.payments (
      customer_id, user_id, company_id, amount, discount, amount_received,
      previous_balance, remaining_balance, transaction_date, notes,
      signature_path, payment_method, payment_method_note, created_at,
      idempotency_key
    ) values (
      p_customer_id, v_user_id, v_company_id, round(p_amount, 2), v_discount,
      v_amount_received, v_previous_balance, v_remaining_balance,
      coalesce(p_transaction_date, now()), p_notes, p_signature_path,
      p_payment_method, p_payment_method_note, coalesce(p_entered_at, now()),
      trim(p_idempotency_key)
    ) returning * into v_payment;
  exception when unique_violation then
    select * into v_payment
    from public.payments
    where company_id = v_company_id
      and idempotency_key = trim(p_idempotency_key);
    if found then
      return v_payment;
    end if;
    raise;
  end;

  insert into public.ledger_entries (
    id, customer_id, user_id, company_id, entry_type, amount, discount,
    amount_received, balance_before, balance_after, transaction_date, notes,
    signature_path, created_at, payment_method, payment_method_note
  ) values (
    v_payment.id, p_customer_id, v_user_id, v_company_id, 'payment',
    round(p_amount, 2), v_discount, v_amount_received, v_previous_balance,
    v_remaining_balance, coalesce(p_transaction_date, now()), p_notes,
    p_signature_path, coalesce(p_entered_at, now()), p_payment_method,
    p_payment_method_note
  );

  return v_payment;
end;
$$;

revoke all on function public.record_payment_idempotent(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz, text
) from public, anon;
grant execute on function public.record_payment_idempotent(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz, text
) to authenticated;
