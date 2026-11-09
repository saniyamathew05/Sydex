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
set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_payment public.payments%rowtype;
  v_customer public.customers%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be logged in.';
  end if;

  select role into v_role
  from public.profiles
  where id = v_user_id;

  if v_role <> 'owner' then
    raise exception 'Only an owner can edit a payment.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount to settle must be greater than zero.';
  end if;

  if p_discount is null or p_discount < 0 or p_discount >= p_amount then
    raise exception 'Discount must be zero or greater and less than the amount.';
  end if;

  if p_payment_method not in ('cash', 'cheque', 'neft', 'gpay') then
    raise exception 'Invalid payment method.';
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment was not found.';
  end if;

  select * into v_customer
  from public.customers
  where id = v_payment.customer_id
  for update;

  if not found then
    raise exception 'Customer was not found.';
  end if;

  update public.payments
  set amount = round(p_amount, 2),
      discount = round(p_discount, 2),
      amount_received = round(p_amount - p_discount, 2),
      notes = p_notes,
      payment_method = p_payment_method,
      payment_method_note = p_payment_method_note,
      transaction_date = coalesce(p_transaction_date, transaction_date)
  where id = p_payment_id;

  update public.ledger_entries
  set amount = round(p_amount, 2),
      discount = round(p_discount, 2),
      amount_received = round(p_amount - p_discount, 2),
      notes = p_notes,
      payment_method = p_payment_method,
      payment_method_note = p_payment_method_note,
      transaction_date = coalesce(p_transaction_date, transaction_date)
  where id = p_payment_id
    and entry_type = 'payment';

  if not found then
    raise exception 'The matching customer ledger entry was not found.';
  end if;

  if exists (
    select 1
    from (
      select round(
        v_customer.opening_balance + sum(
          case
            when entry_type in ('purchase', 'bounced_check') then amount
            when entry_type in ('payment', 'return') then -amount
            else 0
          end
        ) over (
          order by transaction_date, created_at, id
          rows between unbounded preceding and current row
        ),
        2
      ) as running_balance
      from public.ledger_entries
      where customer_id = v_customer.id
    ) balances
    where running_balance < 0
  ) then
    raise exception 'This payment change would make a historical customer balance negative.';
  end if;

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
  update public.ledger_entries entry
  set balance_before = ordered.new_balance_before,
      balance_after = ordered.new_balance_after
  from ordered
  where entry.id = ordered.id;

  update public.payments payment
  set previous_balance = entry.balance_before,
      remaining_balance = entry.balance_after
  from public.ledger_entries entry
  where payment.id = entry.id
    and entry.customer_id = v_customer.id
    and entry.entry_type = 'payment';

  return true;
end
$function$;

revoke all on function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamp with time zone
) from public;

grant execute on function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamp with time zone
) to authenticated;
