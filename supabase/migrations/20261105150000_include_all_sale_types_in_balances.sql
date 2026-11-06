-- Keep the dashboard/customer amount due in sync with the full ledger. Some
-- older rows use `sale`/`sales_return` while newer rows use purchase/return.
create or replace function public.get_customer_balances()
returns table(customer_id uuid, balance numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
    round(
      c.opening_balance + coalesce(sum(case
        when l.entry_type in ('purchase', 'sale', 'bounced_check') then l.amount
        when l.entry_type in ('payment', 'return', 'sales_return') then -l.amount
        else 0
      end), 0), 2
    ) as balance
  from public.customers c
  left join public.ledger_entries l
    on l.customer_id = c.id
   and (l.company_id = c.company_id or l.company_id is null)
  where c.is_active = true
    and (select public.get_my_role()) in ('owner', 'salesman')
  group by c.id, c.opening_balance
$$;

revoke all on function public.get_customer_balances() from public, anon;
grant execute on function public.get_customer_balances() to authenticated;
