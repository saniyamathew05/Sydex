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
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2);
  v_discount numeric(12,2) := coalesce(p_discount, 0);
  v_amount_received numeric(12,2);
  v_remaining_balance numeric(12,2);
  v_payment public.payments;
begin
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  select role into v_role from public.profiles where id = v_user_id;
  if v_role not in ('owner', 'salesman') then raise exception 'You are not allowed to record payments.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount to settle must be greater than zero.'; end if;
  if p_payment_method not in ('cash', 'cheque', 'neft', 'gpay') then raise exception 'Invalid payment method.'; end if;
  if v_discount < 0 or v_discount >= p_amount then raise exception 'Discount must be less than the amount being settled.'; end if;
  v_amount_received := round(p_amount - v_discount, 2);
  select * into v_customer from public.customers where id = p_customer_id and is_active = true for update;
  if not found then raise exception 'Customer was not found or inactive.'; end if;
  select round(v_customer.opening_balance + coalesce(sum(case
    when entry_type = 'purchase' then amount
    when entry_type in ('payment', 'return') then -amount
    when entry_type = 'bounced_check' then amount else 0 end), 0), 2)
    into v_previous_balance from public.ledger_entries where customer_id = p_customer_id;
  v_remaining_balance := round(v_previous_balance - p_amount, 2);
  insert into public.payments (customer_id,user_id,amount,discount,amount_received,previous_balance,remaining_balance,transaction_date,notes,signature_path,payment_method,payment_method_note,created_at)
    values (p_customer_id,v_user_id,round(p_amount,2),v_discount,v_amount_received,v_previous_balance,v_remaining_balance,coalesce(p_transaction_date,now()),p_notes,p_signature_path,p_payment_method,p_payment_method_note,coalesce(p_entered_at,now())) returning * into v_payment;
  insert into public.ledger_entries (id,customer_id,user_id,entry_type,amount,discount,amount_received,balance_before,balance_after,transaction_date,notes,signature_path,created_at,payment_method,payment_method_note)
    values (v_payment.id,p_customer_id,v_user_id,'payment',round(p_amount,2),v_discount,v_amount_received,v_previous_balance,v_remaining_balance,coalesce(p_transaction_date,now()),p_notes,p_signature_path,coalesce(p_entered_at,now()),p_payment_method,p_payment_method_note);
  return v_payment;
end;
$function$;
