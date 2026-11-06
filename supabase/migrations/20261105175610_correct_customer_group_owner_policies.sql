drop policy if exists "Owners manage customer groups" on public.customer_groups;

create policy "Owners create customer groups"
  on public.customer_groups for insert to authenticated
  with check (
    company_id = (select public.current_company_id())
    and created_by = (select auth.uid())
    and exists (
      select 1 from public.company_members cm
      where cm.company_id = customer_groups.company_id
        and cm.user_id = (select auth.uid())
        and cm.role = 'owner'
    )
  );

create policy "Owners update customer groups"
  on public.customer_groups for update to authenticated
  using (
    company_id = (select public.current_company_id())
    and exists (
      select 1 from public.company_members cm
      where cm.company_id = customer_groups.company_id
        and cm.user_id = (select auth.uid())
        and cm.role = 'owner'
    )
  )
  with check (company_id = (select public.current_company_id()));

create policy "Owners delete customer groups"
  on public.customer_groups for delete to authenticated
  using (
    company_id = (select public.current_company_id())
    and exists (
      select 1 from public.company_members cm
      where cm.company_id = customer_groups.company_id
        and cm.user_id = (select auth.uid())
        and cm.role = 'owner'
    )
  );
