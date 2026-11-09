-- Salesmen need a shared view of the customer ledger and received payments.
-- RLS continues to restrict writes to the existing owner/salesman policies.
drop policy if exists "Salesmen can view only their own payments"
  on public.payments;
drop policy if exists "Salesman can view own payments"
  on public.payments;
create policy "Salesmen can view all payments"
  on public.payments
  for select
  to authenticated
  using (get_my_role() = 'salesman');

drop policy if exists "Salesmen can view their own ledger entries"
  on public.ledger_entries;
create policy "Salesmen can view all ledger entries"
  on public.ledger_entries
  for select
  to authenticated
  using (get_my_role() = 'salesman');
