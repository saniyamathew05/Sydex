create or replace function public.record_purchase_with_discount(
  p_customer_id uuid,
  p_amount numeric,
  p_discount numeric,
  p_notes text,
  p_transaction_date timestamp with time zone default now()
)
returns public.ledger_entries
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_role text;
  v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2);
  v_new_balance numeric(12,2);
  v_net_amount numeric(12,2);
  v_entry public.ledger_entries;
begin
  v_user_id := auth.uid();
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  select role into v_role from public.profiles where id = v_user_id;
  if v_role <> 'owner' then raise exception 'Only an owner can record a purchase.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Purchase amount must be greater than zero.'; end if;
  if p_discount is null or p_discount < 0 or p_discount >= p_amount then
    raise exception 'Discount must be less than the purchase amount.';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id and is_active = true
  for update;
  if not found then raise exception 'Customer was not found or is inactive.'; end if;

  v_net_amount := round(p_amount - p_discount, 2);
  if v_net_amount <= 0 then raise exception 'Sale amount after discount must be greater than zero.'; end if;

  select round(greatest(v_customer.opening_balance + coalesce(sum(case
    when entry_type = 'purchase' then amount
    when entry_type in ('payment', 'return') then -amount
    when entry_type = 'bounced_check' then amount
    else 0 end), 0), 0), 2)
  into v_previous_balance
  from public.ledger_entries
  where customer_id = p_customer_id;

  v_new_balance := round(v_previous_balance + v_net_amount, 2);
  insert into public.ledger_entries(
    customer_id, user_id, entry_type, amount, discount, amount_received,
    balance_before, balance_after, transaction_date, notes
  ) values (
    p_customer_id, v_user_id, 'purchase', v_net_amount, round(p_discount, 2),
    v_net_amount, v_previous_balance, v_new_balance,
    coalesce(p_transaction_date, now()), p_notes
  ) returning * into v_entry;
  return v_entry;
end
$function$;

grant execute on function public.record_purchase_with_discount(uuid, numeric, numeric, text, timestamp with time zone)
to authenticated;
