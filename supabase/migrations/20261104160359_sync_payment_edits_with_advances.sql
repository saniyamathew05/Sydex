-- Keep payment edits synchronized across the payment row and customer ledger.
-- Advances may make a running balance negative, so note-only edits must not be
-- rejected by the old pre-advance balance guard.
create or replace function public.update_payment(
  p_payment_id uuid,
  p_amount numeric,
  p_discount numeric,
  p_notes text,
  p_payment_method text,
  p_payment_method_note text,
  p_transaction_date timestamp with time zone
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text := public.get_my_role();
  v_company_id uuid := public.current_company_id();
  v_payment public.payments%rowtype;
  v_customer public.customers%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be logged in.';
  end if;
  if v_role <> 'owner' then
    raise exception 'Only an owner can edit a payment.';
  end if;
  if v_company_id is null then
    raise exception 'Your account is not linked to a company.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount to settle must be greater than zero.';
  end if;
  if p_discount is null or p_discount < 0 or p_discount >= p_amount then
    raise exception 'Discount must be zero or greater and less than the amount.';
  end if;
  if p_payment_method is null
      or p_payment_method not in ('cash', 'cheque', 'neft', 'gpay') then
    raise exception 'Invalid payment method.';
  end if;

  select payment.* into v_payment
  from public.payments as payment
  join public.customers as customer on customer.id = payment.customer_id
  where payment.id = p_payment_id
    and customer.company_id = v_company_id
    and (payment.company_id = v_company_id or payment.company_id is null)
  for update of payment;
  if not found then
    raise exception 'Payment was not found in your company.';
  end if;

  select * into v_customer
  from public.customers
  where id = v_payment.customer_id
    and company_id = v_company_id
  for update;
  if not found then
    raise exception 'Customer was not found in your company.';
  end if;

  update public.payments
  set amount = round(p_amount, 2),
      discount = round(p_discount, 2),
      amount_received = round(p_amount - p_discount, 2),
      notes = p_notes,
      payment_method = p_payment_method,
      payment_method_note = p_payment_method_note,
      transaction_date = coalesce(p_transaction_date, transaction_date),
      company_id = v_company_id
  where id = p_payment_id
    and customer_id = v_customer.id
    and (company_id = v_company_id or company_id is null);

  -- Match both current rows (shared ID) and older rows linked by
  -- related_payment_id, so customer history and payment history stay aligned.
  update public.ledger_entries
  set amount = round(p_amount, 2),
      discount = round(p_discount, 2),
      amount_received = round(p_amount - p_discount, 2),
      notes = p_notes,
      payment_method = p_payment_method,
      payment_method_note = p_payment_method_note,
      transaction_date = coalesce(p_transaction_date, transaction_date),
      company_id = v_company_id
  where entry_type = 'payment'
    and customer_id = v_customer.id
    and (id = p_payment_id or related_payment_id = p_payment_id)
    and (company_id = v_company_id or company_id is null);
  if not found then
    raise exception 'The matching customer ledger entry was not found.';
  end if;

  -- Negative balances are valid customer advances. Recompute all ledger
  -- balances without rejecting note-only edits for those customers.
  with ordered as (
    select
      id,
      round(
        v_customer.opening_balance + coalesce(sum(
          case
            when entry_type in ('purchase', 'bounced_check') then amount
            when entry_type in ('payment', 'return') then -amount
            else 0
          end
        ) over (
          order by transaction_date, created_at, id
          rows between unbounded preceding and 1 preceding
        ), 0),
        2
      ) as new_balance_before,
      round(
        v_customer.opening_balance + coalesce(sum(
          case
            when entry_type in ('purchase', 'bounced_check') then amount
            when entry_type in ('payment', 'return') then -amount
            else 0
          end
        ) over (
          order by transaction_date, created_at, id
          rows between unbounded preceding and current row
        ), 0),
        2
      ) as new_balance_after
    from public.ledger_entries
    where customer_id = v_customer.id
  )
  update public.ledger_entries as entry
  set balance_before = ordered.new_balance_before,
      balance_after = ordered.new_balance_after
  from ordered
  where entry.id = ordered.id;

  update public.payments as payment
  set previous_balance = entry.balance_before,
      remaining_balance = entry.balance_after,
      company_id = v_company_id
  from public.ledger_entries as entry
  where payment.customer_id = v_customer.id
    and (payment.company_id = v_company_id or payment.company_id is null)
    and entry.entry_type = 'payment'
    and (payment.id = entry.id or payment.id = entry.related_payment_id)
    and entry.customer_id = v_customer.id;

  return true;
end;
$$;

revoke all on function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamp with time zone
) from public, anon;
grant execute on function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamp with time zone
) to authenticated;
