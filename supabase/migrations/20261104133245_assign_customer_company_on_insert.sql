-- Fill the authenticated user's company for legacy app builds that omit company_id.
-- RLS continues to enforce that inserts cannot cross company boundaries.
create or replace function public.set_customer_company_id_on_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_company_id uuid;
begin
  if new.company_id is null then
    v_company_id := public.current_company_id();
    if v_company_id is null then
      raise exception 'Your account is not linked to a company.';
    end if;
    new.company_id := v_company_id;
  end if;

  return new;
end;
$$;

create trigger customers_set_company_id_before_insert
before insert on public.customers
for each row
execute function public.set_customer_company_id_on_insert();
