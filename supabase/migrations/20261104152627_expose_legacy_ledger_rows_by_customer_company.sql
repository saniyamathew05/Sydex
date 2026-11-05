-- Older ledger rows may not have company_id populated. Scope those rows by
-- their owning customer so existing history stays visible without rewriting it.
drop policy if exists "Company users can view ledger entries"
  on public.ledger_entries;

create policy "Company users can view ledger entries"
  on public.ledger_entries
  for select
  to authenticated
  using (
    company_id = (select public.current_company_id())
    or (
      company_id is null
      and exists (
        select 1
        from public.customers as customer
        where customer.id = ledger_entries.customer_id
          and customer.company_id = (select public.current_company_id())
      )
    )
  );
