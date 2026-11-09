drop policy if exists "Salesmen can view daily visit statuses" on public.salesman_customer_daily_status;
create policy "Salesmen can view daily visit statuses"
on public.salesman_customer_daily_status
for select
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and lower(p.role) in ('salesman', 'owner')
  )
);
