-- Ledger imports may contain historical financial data. Owner access must
-- always be constrained to the active business workspace.
drop policy if exists "Owners can view ledger import batches" on public.ledger_import_batches;
create policy "Owners can view company ledger import batches"
  on public.ledger_import_batches
  for select
  to authenticated
  using (
    company_id = (select public.current_company_id())
    and (select public.get_my_role()) = 'owner'
  );
