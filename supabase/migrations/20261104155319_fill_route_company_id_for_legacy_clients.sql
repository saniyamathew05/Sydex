-- Older installed clients omit company_id when creating route templates and
-- daily route selections. Fill it from the signed-in user's company before
-- RLS evaluates WITH CHECK, while rejecting cross-company writes.
create or replace function public.set_route_company_id_before_write()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_company_id uuid;
begin
  -- Trusted database migrations and service-role jobs may write without an
  -- end-user JWT; application clients are scoped below.
  if auth.uid() is null then
    return new;
  end if;

  v_company_id := public.current_company_id();
  if v_company_id is null then
    raise exception 'Your account is not linked to a company.';
  end if;

  if new.company_id is not null and new.company_id is distinct from v_company_id then
    raise exception 'Route data cannot be written to another company.';
  end if;

  new.company_id := v_company_id;
  return new;
end;
$$;

drop trigger if exists salesman_route_templates_set_company_id
  on public.salesman_route_templates;
create trigger salesman_route_templates_set_company_id
before insert or update of company_id on public.salesman_route_templates
for each row execute function public.set_route_company_id_before_write();

drop trigger if exists salesman_daily_route_selections_set_company_id
  on public.salesman_daily_route_selections;
create trigger salesman_daily_route_selections_set_company_id
before insert or update of company_id on public.salesman_daily_route_selections
for each row execute function public.set_route_company_id_before_write();

revoke all on function public.set_route_company_id_before_write()
  from public, anon, authenticated;
