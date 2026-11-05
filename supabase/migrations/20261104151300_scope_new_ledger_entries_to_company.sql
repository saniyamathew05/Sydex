-- Keep newly recorded sales and payments visible through company-scoped RLS.
-- Existing ledger rows are intentionally left untouched.
create or replace function public.record_purchase_with_discount(
  p_customer_id uuid,
  p_amount numeric,
  p_discount numeric,
  p_notes text,
  p_transaction_date timestamptz default now()
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text := public.get_my_role();
  v_company_id uuid := public.current_company_id();
  v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2);
  v_new_balance numeric(12,2);
  v_net_amount numeric(12,2);
  v_entry public.ledger_entries;
begin
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  if v_role <> 'owner' then raise exception 'Only an owner can record a purchase.'; end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Purchase amount must be greater than zero.'; end if;
  if p_discount is null or p_discount < 0 or p_discount >= p_amount then
    raise exception 'Discount must be less than the purchase amount.';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id and is_active = true
  for update;
  if not found then raise exception 'Customer was not found or is inactive.'; end if;
  if v_customer.company_id is distinct from v_company_id then
    raise exception 'Customer does not belong to your company.';
  end if;

  v_net_amount := round(p_amount - p_discount, 2);
  if v_net_amount <= 0 then raise exception 'Sale amount after discount must be greater than zero.'; end if;

  select round(v_customer.opening_balance + coalesce(sum(case
    when entry_type = 'purchase' then amount
    when entry_type in ('payment', 'return') then -amount
    when entry_type = 'bounced_check' then amount
    else 0 end), 0), 2)
  into v_previous_balance
  from public.ledger_entries
  where customer_id = p_customer_id and company_id = v_company_id;

  v_new_balance := round(v_previous_balance + v_net_amount, 2);
  insert into public.ledger_entries (
    customer_id, user_id, company_id, entry_type, amount, discount,
    amount_received, balance_before, balance_after, transaction_date, notes
  ) values (
    p_customer_id, v_user_id, v_company_id, 'purchase', v_net_amount,
    round(p_discount, 2), v_net_amount, v_previous_balance, v_new_balance,
    coalesce(p_transaction_date, now()), p_notes
  ) returning * into v_entry;
  return v_entry;
end;
$function$;

revoke all on function public.record_purchase_with_discount(
  uuid, numeric, numeric, text, timestamptz
) from public, anon;
grant execute on function public.record_purchase_with_discount(
  uuid, numeric, numeric, text, timestamptz
) to authenticated;

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
  v_company_id uuid := public.current_company_id();
  v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2);
  v_discount numeric(12,2) := coalesce(p_discount, 0);
  v_amount_received numeric(12,2);
  v_remaining_balance numeric(12,2);
  v_entered_at timestamptz := coalesce(p_entered_at, now());
  v_payment public.payments;
begin
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  if v_role not in ('owner', 'salesman') then raise exception 'You are not allowed to record payments.'; end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount to settle must be greater than zero.'; end if;
  if p_payment_method not in ('cash', 'cheque', 'neft', 'gpay') then raise exception 'Invalid payment method.'; end if;
  if v_discount < 0 or v_discount >= p_amount then raise exception 'Discount must be less than the amount being settled.'; end if;
  v_amount_received := round(p_amount - v_discount, 2);
  if v_amount_received <= 0 then raise exception 'Amount actually received must be greater than zero.'; end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id and is_active = true
  for update;
  if not found then raise exception 'Customer was not found or is inactive.'; end if;
  if v_customer.company_id is distinct from v_company_id then
    raise exception 'Customer does not belong to your company.';
  end if;

  select round(v_customer.opening_balance + coalesce(sum(case
    when entry_type = 'purchase' then amount
    when entry_type in ('payment', 'return') then -amount
    when entry_type = 'bounced_check' then amount
    else 0 end), 0), 2)
  into v_previous_balance
  from public.ledger_entries
  where customer_id = p_customer_id and company_id = v_company_id;
  v_remaining_balance := round(v_previous_balance - p_amount, 2);

  insert into public.payments (
    customer_id, user_id, company_id, amount, discount, amount_received,
    previous_balance, remaining_balance, transaction_date, notes,
    signature_path, payment_method, payment_method_note, created_at
  ) values (
    p_customer_id, v_user_id, v_company_id, round(p_amount, 2), v_discount,
    v_amount_received, v_previous_balance, v_remaining_balance,
    coalesce(p_transaction_date, now()), p_notes, p_signature_path,
    p_payment_method, p_payment_method_note, v_entered_at
  ) returning * into v_payment;

  insert into public.ledger_entries (
    id, customer_id, user_id, company_id, entry_type, amount, discount,
    amount_received, balance_before, balance_after, transaction_date, notes,
    signature_path, created_at, payment_method, payment_method_note
  ) values (
    v_payment.id, p_customer_id, v_user_id, v_company_id, 'payment',
    round(p_amount, 2), v_discount, v_amount_received, v_previous_balance,
    v_remaining_balance, coalesce(p_transaction_date, now()), p_notes,
    p_signature_path, v_entered_at, p_payment_method, p_payment_method_note
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
