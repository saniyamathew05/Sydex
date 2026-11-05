-- A payment above the current amount due is customer credit (an advance).
-- Keep the negative balance in the ledger so it remains visible and usable.
alter table public.ledger_entries
  drop constraint if exists ledger_entries_balance_before_check,
  drop constraint if exists ledger_entries_balance_after_check;

alter table public.payments
  drop constraint if exists payments_previous_balance_check,
  drop constraint if exists payments_remaining_balance_check;

create or replace function public.record_payment_with_phone_time(
  p_customer_id uuid,
  p_amount numeric,
  p_discount numeric default 0,
  p_notes text default null,
  p_signature_path text default null,
  p_transaction_date timestamptz default now(),
  p_payment_method text default 'cash',
  p_payment_method_note text default null,
  p_entered_at timestamptz default now()
)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text := public.get_my_role();
  v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2);
  v_discount numeric(12,2) := coalesce(p_discount, 0);
  v_amount_received numeric(12,2);
  v_remaining_balance numeric(12,2);
  v_entered_at timestamptz := coalesce(p_entered_at, now());
  v_payment public.payments;
begin
  if v_user_id is null then
    raise exception 'You must be logged in.';
  end if;
  if v_role not in ('owner', 'salesman') then
    raise exception 'You are not allowed to record payments.';
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
  where id = p_customer_id and is_active = true
  for update;
  if not found then
    raise exception 'Customer was not found or is inactive.';
  end if;
  if v_customer.company_id is distinct from public.current_company_id() then
    raise exception 'Customer does not belong to your company.';
  end if;

  select round(
    v_customer.opening_balance + coalesce(sum(case
      when entry_type = 'purchase' then amount
      when entry_type in ('payment', 'return') then -amount
      when entry_type = 'bounced_check' then amount
      else 0
    end), 0), 2
  ) into v_previous_balance
  from public.ledger_entries
  where customer_id = p_customer_id;

  v_remaining_balance := round(v_previous_balance - p_amount, 2);

  insert into public.payments (
    customer_id, user_id, amount, discount, amount_received,
    previous_balance, remaining_balance, transaction_date,
    notes, signature_path, payment_method, payment_method_note, created_at
  ) values (
    p_customer_id, v_user_id, round(p_amount, 2), v_discount, v_amount_received,
    v_previous_balance, v_remaining_balance,
    coalesce(p_transaction_date, now()), p_notes, p_signature_path,
    p_payment_method, p_payment_method_note, v_entered_at
  ) returning * into v_payment;

  insert into public.ledger_entries (
    id, customer_id, user_id, entry_type, amount, discount, amount_received,
    balance_before, balance_after, transaction_date, notes, signature_path,
    created_at, payment_method, payment_method_note
  ) values (
    v_payment.id, p_customer_id, v_user_id, 'payment', round(p_amount, 2),
    v_discount, v_amount_received, v_previous_balance, v_remaining_balance,
    coalesce(p_transaction_date, now()), p_notes, p_signature_path,
    v_entered_at, p_payment_method, p_payment_method_note
  );

  return v_payment;
end;
$function$;

revoke all on function public.record_payment_with_phone_time(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz
) from public, anon;
grant execute on function public.record_payment_with_phone_time(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz
) to authenticated;

create or replace function public.get_customer_balances()
returns table(customer_id uuid, balance numeric)
language sql
stable
security definer
set search_path = ''
as $function$
  select c.id,
    round(c.opening_balance + coalesce(sum(case
      when l.entry_type = 'purchase' then l.amount
      when l.entry_type in ('payment', 'return') then -l.amount
      when l.entry_type = 'bounced_check' then l.amount
      else 0
    end), 0), 2) as balance
  from public.customers c
  left join public.ledger_entries l on l.customer_id = c.id
  where c.is_active = true
    and c.company_id = (select public.current_company_id())
    and (select public.get_my_role()) in ('owner', 'salesman')
  group by c.id, c.opening_balance
$function$;

revoke all on function public.get_customer_balances() from public, anon;
grant execute on function public.get_customer_balances() to authenticated;
