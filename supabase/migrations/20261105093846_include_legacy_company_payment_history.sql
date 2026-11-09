-- Preserve historical payment and customer names inside their own business.
-- Legacy payment rows have no company_id; their customer identifies the owner company.
drop policy if exists "Company users can view payments" on public.payments;
create policy "Company users can view payments"
  on public.payments
  for select
  to authenticated
  using (
    company_id = (select public.current_company_id())
    or (
      company_id is null
      and exists (
        select 1
        from public.customers as customer
        where customer.id = payments.customer_id
          and customer.company_id = (select public.current_company_id())
      )
    )
  );

-- Salesmen need the customer name for historical payments even after that
-- customer is deactivated. App customer lists still request active rows only.
drop policy if exists "Salesmen can view active customers in company"
  on public.customers;
create policy "Salesmen can view customers in company"
  on public.customers
  for select
  to authenticated
  using (
    company_id = (select public.current_company_id())
    and (select public.get_my_role()) = 'salesman'
  );
