-- Sales returns may create customer credit; negative balances mean money owed to the customer.
alter table public.ledger_entries drop constraint if exists ledger_entries_balance_before_check;
alter table public.ledger_entries drop constraint if exists ledger_entries_balance_after_check;

CREATE OR REPLACE FUNCTION public.delete_purchase(p_entry_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid; v_role text; v_entry public.ledger_entries; v_customer public.customers%rowtype;
begin
  v_user_id:=auth.uid();
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  select role into v_role from public.profiles where id=v_user_id;
  if v_role<>'owner' then raise exception 'Only an owner can delete a purchase.'; end if;
  select * into v_entry from public.ledger_entries where id=p_entry_id and entry_type='purchase' for update;
  if not found then raise exception 'Purchase was not found.'; end if;
  select * into v_customer from public.customers where id=v_entry.customer_id for update;
  if not found then raise exception 'Customer was not found.'; end if;
  delete from public.ledger_entries where id=p_entry_id and entry_type='purchase';
  if exists (
    select 1 from (
      select entry_type, round(v_customer.opening_balance + sum(case
        when entry_type='purchase' then amount
        when entry_type in ('payment','return') then -amount
        when entry_type='bounced_check' then amount
        else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and current row),2) running_balance
      from public.ledger_entries where customer_id=v_customer.id
    ) balances where entry_type = 'payment' and running_balance < 0
  ) then raise exception 'This purchase cannot be deleted because a historical payment depends on it.'; end if;
  with ordered as (
    select id,
      round(v_customer.opening_balance+coalesce(sum(case
        when entry_type='purchase' then amount
        when entry_type in ('payment','return') then -amount
        when entry_type='bounced_check' then amount
        else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and 1 preceding),0),2) new_balance_before,
      round(v_customer.opening_balance+coalesce(sum(case
        when entry_type='purchase' then amount
        when entry_type in ('payment','return') then -amount
        when entry_type='bounced_check' then amount
        else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and current row),0),2) new_balance_after
    from public.ledger_entries where customer_id=v_customer.id
  )
  update public.ledger_entries l set balance_before=o.new_balance_before,balance_after=o.new_balance_after
  from ordered o where l.id=o.id;
  update public.payments p set previous_balance=l.balance_before,remaining_balance=l.balance_after
  from public.ledger_entries l where p.id=l.id and l.customer_id=v_customer.id and l.entry_type='payment';
end $function$;


CREATE OR REPLACE FUNCTION public.get_customer_balances()
 RETURNS TABLE(customer_id uuid, balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id,
    round(
      c.opening_balance + coalesce(sum(case
        when l.entry_type = 'purchase' then l.amount
        when l.entry_type in ('payment','return') then -l.amount
        when l.entry_type = 'bounced_check' then l.amount
        else 0
      end),0),2) as balance
  from public.customers c
  left join public.ledger_entries l on l.customer_id = c.id
  where c.is_active = true
  group by c.id,c.opening_balance;
$function$;


CREATE OR REPLACE FUNCTION public.record_bounced_cheque(p_payment_id uuid, p_bank_charge numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_transaction_date timestamp with time zone DEFAULT now(), p_add_bank_charge boolean DEFAULT true)
 RETURNS ledger_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid;
  v_role text;
  v_payment public.payments%rowtype;
  v_customer public.customers%rowtype;
  v_before numeric(12,2);
  v_after numeric(12,2);
  v_total numeric(12,2);
  v_charge numeric(12,2);
  v_entry public.ledger_entries;
begin
  v_user_id := auth.uid();
  if v_user_id is null then raise exception 'You must be logged in.'; end if;

  select role into v_role from public.profiles where id = v_user_id;
  if v_role <> 'owner' then
    raise exception 'Only an owner can mark a cheque as bounced.';
  end if;

  if coalesce(p_bank_charge,0) < 0 then
    raise exception 'Bank charge cannot be negative.';
  end if;

  v_charge := case when coalesce(p_add_bank_charge,true) then round(coalesce(p_bank_charge,0),2) else 0 end;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then raise exception 'Payment was not found.'; end if;
  if v_payment.payment_method <> 'cheque' then
    raise exception 'Only cheque payments can be marked as bounced.';
  end if;
  if v_payment.is_bounced then
    raise exception 'This cheque has already been marked as bounced.';
  end if;

  select * into v_customer
  from public.customers
  where id = v_payment.customer_id and is_active = true
  for update;

  if not found then raise exception 'Customer was not found or is inactive.'; end if;

  select round(
    v_customer.opening_balance +
    coalesce(sum(case
      when entry_type = 'purchase' then amount
      when entry_type in ('payment','return') then -amount
      when entry_type = 'bounced_check' then amount
      else 0
    end),0),2)
  into v_before
  from public.ledger_entries
  where customer_id = v_payment.customer_id;

  v_total := round(v_payment.amount + v_charge,2);
  v_after := round(v_before + v_total,2);

  update public.payments set is_bounced = true where id = v_payment.id;

  update public.ledger_entries
  set is_bounced = true
  where id = v_payment.id and entry_type = 'payment';

  insert into public.ledger_entries (
    customer_id,user_id,entry_type,amount,discount,amount_received,
    balance_before,balance_after,transaction_date,notes,created_at,
    payment_method,payment_method_note,related_payment_id,bank_charge,is_bounced
  )
  values (
    v_payment.customer_id,v_user_id,'bounced_check',v_total,0,0,
    v_before,v_after,coalesce(p_transaction_date,now()),
    case
      when v_charge > 0 and nullif(trim(p_notes),'') is not null then p_notes
      when v_charge > 0 then 'Bank charge added to customer balance.'
      when nullif(trim(p_notes),'') is not null then p_notes
      else 'Cheque bounced. Bank charge ignored.'
    end,
    now(),
    'cheque',null,v_payment.id,v_charge,true
  )
  returning * into v_entry;

  return v_entry;
end;
$function$;


CREATE OR REPLACE FUNCTION public.record_purchase(p_customer_id uuid, p_amount numeric, p_notes text, p_transaction_date timestamp with time zone DEFAULT now())
 RETURNS ledger_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid; v_role text; v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2); v_new_balance numeric(12,2);
  v_entry public.ledger_entries;
begin
  v_user_id := auth.uid();
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  select role into v_role from public.profiles where id=v_user_id;
  if v_role <> 'owner' then raise exception 'Only an owner can record a purchase.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Purchase amount must be greater than zero.'; end if;
  select * into v_customer from public.customers where id=p_customer_id and is_active=true for update;
  if not found then raise exception 'Customer was not found or is inactive.'; end if;
  select round(v_customer.opening_balance + coalesce(sum(case
    when entry_type='purchase' then amount
    when entry_type in ('payment','return') then -amount
    when entry_type='bounced_check' then amount
    else 0 end),0),2)
  into v_previous_balance from public.ledger_entries where customer_id=p_customer_id;
  v_new_balance := round(v_previous_balance+p_amount,2);
  insert into public.ledger_entries(customer_id,user_id,entry_type,amount,balance_before,balance_after,transaction_date,notes)
  values(p_customer_id,v_user_id,'purchase',round(p_amount,2),v_previous_balance,v_new_balance,coalesce(p_transaction_date,now()),p_notes)
  returning * into v_entry;
  return v_entry;
end $function$;


CREATE OR REPLACE FUNCTION public.record_purchase_with_discount(p_customer_id uuid, p_amount numeric, p_discount numeric, p_notes text, p_transaction_date timestamp with time zone DEFAULT now())
 RETURNS ledger_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  select * into v_customer from public.customers where id = p_customer_id and is_active = true for update;
  if not found then raise exception 'Customer was not found or is inactive.'; end if;
  v_net_amount := round(p_amount - p_discount, 2);
  if v_net_amount <= 0 then raise exception 'Sale amount after discount must be greater than zero.'; end if;
  select round(v_customer.opening_balance + coalesce(sum(case
    when entry_type = 'purchase' then amount
    when entry_type in ('payment', 'return') then -amount
    when entry_type = 'bounced_check' then amount
    else 0 end), 0), 2)
  into v_previous_balance from public.ledger_entries where customer_id = p_customer_id;
  v_new_balance := round(v_previous_balance + v_net_amount, 2);
  insert into public.ledger_entries(
    customer_id, user_id, entry_type, amount, discount, amount_received,
    balance_before, balance_after, transaction_date, notes
  ) values (
    p_customer_id, v_user_id, 'purchase', v_net_amount, round(p_discount, 2),
    v_net_amount, v_previous_balance, v_new_balance, coalesce(p_transaction_date, now()), p_notes
  ) returning * into v_entry;
  return v_entry;
end
$function$;


CREATE OR REPLACE FUNCTION public.record_return(p_customer_id uuid, p_amount numeric, p_notes text, p_transaction_date timestamp with time zone DEFAULT now())
 RETURNS ledger_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid; v_role text; v_customer public.customers%rowtype;
  v_previous_balance numeric(12,2); v_new_balance numeric(12,2);
  v_entry public.ledger_entries;
begin
  v_user_id:=auth.uid();
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  select role into v_role from public.profiles where id=v_user_id;
  if v_role is null or v_role not in ('owner','salesman') then raise exception 'You do not have permission to record a return.'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Return amount must be greater than zero.'; end if;
  select * into v_customer from public.customers where id=p_customer_id and is_active=true for update;
  if not found then raise exception 'Customer was not found.'; end if;
  select round(v_customer.opening_balance + coalesce(sum(case
    when entry_type='purchase' then amount
    when entry_type in ('payment','return') then -amount
    when entry_type='bounced_check' then amount
    else 0 end),0),2)
  into v_previous_balance from public.ledger_entries where customer_id=p_customer_id;
  v_new_balance:=round(v_previous_balance-p_amount,2);
  insert into public.ledger_entries(customer_id,user_id,entry_type,amount,discount,amount_received,balance_before,balance_after,transaction_date,notes)
  values(p_customer_id,v_user_id,'return',round(p_amount,2),0,0,v_previous_balance,v_new_balance,coalesce(p_transaction_date,now()),p_notes)
  returning * into v_entry;
  return v_entry;
end $function$;


CREATE OR REPLACE FUNCTION public.update_payment(p_payment_id uuid, p_amount numeric, p_discount numeric, p_notes text, p_payment_method text, p_payment_method_note text, p_transaction_date timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      select entry_type, round(
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
    where entry_type = 'payment' and running_balance < 0
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


CREATE OR REPLACE FUNCTION public.update_purchase(p_entry_id uuid, p_amount numeric, p_notes text, p_transaction_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS ledger_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid; v_role text; v_entry public.ledger_entries;
  v_customer public.customers%rowtype; v_updated public.ledger_entries;
begin
  v_user_id:=auth.uid();
  if v_user_id is null then raise exception 'You must be logged in.'; end if;
  select role into v_role from public.profiles where id=v_user_id;
  if v_role<>'owner' then raise exception 'Only an owner can edit a purchase.'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Purchase amount must be greater than zero.'; end if;
  select * into v_entry from public.ledger_entries where id=p_entry_id and entry_type='purchase' for update;
  if not found then raise exception 'Purchase was not found.'; end if;
  select * into v_customer from public.customers where id=v_entry.customer_id for update;
  if not found then raise exception 'Customer was not found.'; end if;
  update public.ledger_entries set amount=round(p_amount,2),notes=p_notes,transaction_date=coalesce(p_transaction_date,transaction_date)
  where id=p_entry_id returning * into v_updated;
  if exists (
    select 1 from (
      select entry_type, round(v_customer.opening_balance+sum(case
        when entry_type='purchase' then amount
        when entry_type in ('payment','return') then -amount
        when entry_type='bounced_check' then amount
        else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and current row),2) running_balance
      from public.ledger_entries where customer_id=v_customer.id
    ) balances where entry_type = 'payment' and running_balance < 0
  ) then raise exception 'This purchase change would make a historical customer balance negative.'; end if;
  with ordered as (
    select id,
      round(v_customer.opening_balance+coalesce(sum(case
        when entry_type='purchase' then amount
        when entry_type in ('payment','return') then -amount
        when entry_type='bounced_check' then amount
        else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and 1 preceding),0),2) new_balance_before,
      round(v_customer.opening_balance+coalesce(sum(case
        when entry_type='purchase' then amount
        when entry_type in ('payment','return') then -amount
        when entry_type='bounced_check' then amount
        else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and current row),0),2) new_balance_after
    from public.ledger_entries where customer_id=v_customer.id
  )
  update public.ledger_entries l set balance_before=o.new_balance_before,balance_after=o.new_balance_after
  from ordered o where l.id=o.id;
  update public.payments p set previous_balance=l.balance_before,remaining_balance=l.balance_after
  from public.ledger_entries l where p.id=l.id and l.customer_id=v_customer.id and l.entry_type='payment';
  select * into v_updated from public.ledger_entries where id=p_entry_id;
  return v_updated;
end $function$;
