-- Permit a salesman to read only the named route template whose locations
-- exactly match their latest non-empty assignment. Array order is irrelevant.
drop policy if exists "Salesmen can read route templates"
  on public.salesman_route_templates;

create policy "Salesmen can read route templates"
  on public.salesman_route_templates
  for select
  to authenticated
  using (
    get_my_role() = 'salesman'
    and exists (
      select 1
      from public.salesman_daily_route_selections as assignment
      where assignment.salesman_id = auth.uid()
        and cardinality(assignment.locations) > 0
        and assignment.locations @> salesman_route_templates.locations
        and salesman_route_templates.locations @> assignment.locations
        and assignment.route_date = (
          select max(latest.route_date)
          from public.salesman_daily_route_selections as latest
          where latest.salesman_id = auth.uid()
            and latest.route_date <= timezone('Asia/Kolkata', now())::date
        )
    )
  );
