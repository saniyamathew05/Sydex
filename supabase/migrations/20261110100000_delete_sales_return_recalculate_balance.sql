create or replace function public.delete_sales_return(p_entry_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_role text; v_entry public.ledger_entries%rowtype; v_customer public.customers%rowtype;
begin
 select role into v_role from public.profiles where id=v_user;
 if v_user is null or v_role <> 'owner' then raise exception 'Only an owner can delete a sales return.'; end if;
 select * into v_entry from public.ledger_entries where id=p_entry_id and entry_type in ('return','sales_return') for update;
 if not found then raise exception 'Sales return was not found.'; end if;
 select * into v_customer from public.customers where id=v_entry.customer_id for update;
 delete from public.ledger_entries where id=p_entry_id;
 with ordered as (
   select id,
     round(v_customer.opening_balance+coalesce(sum(case when entry_type in ('purchase','bounced_check') then amount when entry_type in ('payment','return','sales_return') then -amount else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and 1 preceding),0),2) before_balance,
     round(v_customer.opening_balance+coalesce(sum(case when entry_type in ('purchase','bounced_check') then amount when entry_type in ('payment','return','sales_return') then -amount else 0 end) over(order by transaction_date,created_at,id rows between unbounded preceding and current row),0),2) after_balance
   from public.ledger_entries where customer_id=v_customer.id
 ) update public.ledger_entries l set balance_before=o.before_balance,balance_after=o.after_balance from ordered o where l.id=o.id;
 update public.payments p set previous_balance=l.balance_before,remaining_balance=l.balance_after from public.ledger_entries l where p.id=l.id and l.customer_id=v_customer.id and l.entry_type='payment';
 return true;
end $$;
revoke all on function public.delete_sales_return(uuid) from public,anon;
grant execute on function public.delete_sales_return(uuid) to authenticated;
