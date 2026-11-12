-- Prevent duplicate queued copies of the same owner assignment and consume
-- any legacy duplicates together when that route becomes active.

create or replace function public.queue_or_assign_salesman_route(
  p_salesman_id uuid,
  p_locations text[],
  p_customer_ids jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.current_company_id();
  v_active public.salesman_daily_route_selections%rowtype;
  v_today date := timezone('Asia/Kolkata', now())::date;
begin
  if auth.uid() is null or public.get_my_role() <> 'owner' then
    raise exception 'Only an owner can assign routes.';
  end if;
  if v_company_id is null then
    raise exception 'Your account is not linked to a company.';
  end if;
  if p_salesman_id is null or jsonb_typeof(coalesce(p_customer_ids, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_customer_ids, '[]'::jsonb)) = 0 then
    raise exception 'A route needs at least one customer.';
  end if;
  if not exists (
    select 1 from public.company_members
    where company_id = v_company_id and user_id = p_salesman_id and role = 'salesman'
  ) then
    raise exception 'The selected user is not a salesman in this business.';
  end if;

  select * into v_active
  from public.salesman_daily_route_selections
  where company_id = v_company_id and salesman_id = p_salesman_id
    and route_date <= v_today
  order by route_date desc limit 1 for update;

  if found and jsonb_array_length(coalesce(v_active.customer_ids, '[]'::jsonb)) > 0 then
    if not exists (
      select 1 from public.salesman_route_queue q
      where q.company_id = v_company_id and q.salesman_id = p_salesman_id
        and q.customer_ids = p_customer_ids
        and q.locations = coalesce(p_locations, '{}'::text[])
    ) then
      insert into public.salesman_route_queue (
        company_id, salesman_id, locations, customer_ids, queued_by
      ) values (
        v_company_id, p_salesman_id, coalesce(p_locations, '{}'::text[]),
        p_customer_ids, auth.uid()
      );
    end if;
    return 'queued';
  end if;

  insert into public.salesman_daily_route_selections (
    company_id, salesman_id, route_date, locations, customer_ids
  ) values (
    v_company_id, p_salesman_id, v_today, coalesce(p_locations, '{}'::text[]), p_customer_ids
  ) on conflict (salesman_id, route_date) do update
  set company_id = excluded.company_id, locations = excluded.locations,
      customer_ids = excluded.customer_ids, updated_at = now();
  return 'active';
end;
$$;

create or replace function public.activate_next_salesman_route(
  p_salesman_id uuid, p_allow_owner boolean default false
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.current_company_id();
  v_next public.salesman_route_queue%rowtype;
  v_today date := timezone('Asia/Kolkata', now())::date;
begin
  if auth.uid() is null then raise exception 'You must be logged in.'; end if;
  if p_allow_owner then
    if public.get_my_role() <> 'owner' then raise exception 'Only an owner can remove another salesman route.'; end if;
  elsif auth.uid() <> p_salesman_id or public.get_my_role() <> 'salesman' then
    raise exception 'You can only finish your own route.';
  end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  if not exists (
    select 1 from public.company_members
    where company_id = v_company_id and user_id = p_salesman_id and role = 'salesman'
  ) then raise exception 'The selected user is not a salesman in this business.'; end if;

  select * into v_next from public.salesman_route_queue
  where company_id = v_company_id and salesman_id = p_salesman_id
  order by created_at, id limit 1 for update skip locked;
  if found then
    insert into public.salesman_daily_route_selections (
      company_id, salesman_id, route_date, locations, customer_ids
    ) values (v_company_id, p_salesman_id, v_today, v_next.locations, v_next.customer_ids)
    on conflict (salesman_id, route_date) do update
    set company_id = excluded.company_id, locations = excluded.locations,
        customer_ids = excluded.customer_ids, updated_at = now();
    delete from public.salesman_route_queue
    where company_id = v_company_id and salesman_id = p_salesman_id
      and customer_ids = v_next.customer_ids and locations = v_next.locations;
    return 'next_route_activated';
  end if;

  insert into public.salesman_daily_route_selections (
    company_id, salesman_id, route_date, locations, customer_ids
  ) values (v_company_id, p_salesman_id, v_today, '{}'::text[], '[]'::jsonb)
  on conflict (salesman_id, route_date) do update
  set company_id = excluded.company_id, locations = excluded.locations,
      customer_ids = excluded.customer_ids, updated_at = now();
  return 'route_finished';
end;
$$;
