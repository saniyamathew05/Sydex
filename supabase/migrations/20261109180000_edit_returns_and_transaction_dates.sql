create or replace function public.update_return(
  p_entry_id uuid,
  p_amount numeric,
  p_notes text,
  p_transaction_date timestamptz
)
returns public.ledger_entries
language plpgsql security definer set search_path = public
as $$
declare v_user uuid := auth.uid(); v_role text; v_entry public.ledger_entries; v_customer public.customers%rowtype; v_updated public.ledger_entries;
begin
  select role into v_role from public.profiles where id=v_user;
  if v_user is null or v_role not in ('owner','salesman') then raise exception 'Not authorized'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Return amount must be greater than zero.'; end if;
  select * into v_entry from public.ledger_entries where id=p_entry_id and entry_type in ('return','sales_return') for update;
  if not found then raise exception 'Sales return was not found.'; end if;
  if v_role='salesman' and v_entry.user_id is distinct from v_user then raise exception 'You can edit only your own return.'; end if;
  select * into v_customer from public.customers where id=v_entry.customer_id for update;
  update public.ledger_entries set amount=round(p_amount,2), notes=p_notes, transaction_date=coalesce(p_transaction_date,transaction_date) where id=p_entry_id returning * into v_updated;
  with ordered as (
    select id,
      round(v_customer.opening_balance + coalesce(sum(case when entry_type in ('purchase','bounced_check') then amount when entry_type in ('payment','return','sales_return') then -amount else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and 1 preceding),0),2) before_balance,
      round(v_customer.opening_balance + coalesce(sum(case when entry_type in ('purchase','bounced_check') then amount when entry_type in ('payment','return','sales_return') then -amount else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and current row),0),2) after_balance
    from public.ledger_entries where customer_id=v_customer.id)
  update public.ledger_entries l set balance_before=o.before_balance,balance_after=o.after_balance from ordered o where l.id=o.id;
  select * into v_updated from public.ledger_entries where id=p_entry_id;
  return v_updated;
end $$;

create or replace function public.update_payment_date(p_payment_id uuid, p_transaction_date timestamptz)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_role text; v_customer uuid;
begin
  select role into v_role from public.profiles where id=v_user;
  select customer_id into v_customer from public.payments where id=p_payment_id and user_id=v_user;
  if v_role <> 'salesman' or v_customer is null then raise exception 'Only the payment owner can edit this date.'; end if;
  update public.payments set transaction_date=p_transaction_date where id=p_payment_id;
  update public.ledger_entries set transaction_date=p_transaction_date where id=p_payment_id and entry_type='payment';
  return true;
end $$;

create or replace function public.update_return_date(p_entry_id uuid, p_transaction_date timestamptz)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_role text; v_owner uuid;
begin
  select role into v_role from public.profiles where id=v_user;
  select user_id into v_owner from public.ledger_entries where id=p_entry_id and entry_type in ('return','sales_return');
  if v_role <> 'salesman' or v_owner is distinct from v_user then raise exception 'Only the return owner can edit this date.'; end if;
  update public.ledger_entries set transaction_date=p_transaction_date where id=p_entry_id;
  return true;
end $$;

revoke all on function public.update_return(uuid,numeric,text,timestamptz) from public,anon;
revoke all on function public.update_payment_date(uuid,timestamptz) from public,anon;
revoke all on function public.update_return_date(uuid,timestamptz) from public,anon;
grant execute on function public.update_return(uuid,numeric,text,timestamptz) to authenticated;
grant execute on function public.update_payment_date(uuid,timestamptz) to authenticated;
grant execute on function public.update_return_date(uuid,timestamptz) to authenticated;
