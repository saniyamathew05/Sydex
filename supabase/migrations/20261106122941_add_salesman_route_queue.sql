-- Queue owner-assigned routes while a salesman has an active route. A queued
-- route becomes active only when that salesman finishes their current route or
-- when the owner removes it. Daily visit/refusal records are never modified.

create table if not exists public.salesman_route_queue (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  salesman_id uuid not null references auth.users(id) on delete cascade,
  locations text[] not null default '{}'::text[],
  customer_ids jsonb not null default '[]'::jsonb,
  queued_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  check (jsonb_typeof(customer_ids) = 'array')
);

create index if not exists salesman_route_queue_next_idx
  on public.salesman_route_queue (company_id, salesman_id, created_at, id);

alter table public.salesman_route_queue enable row level security;

drop policy if exists "Company users read their queued routes" on public.salesman_route_queue;
create policy "Company users read their queued routes"
  on public.salesman_route_queue for select
  to authenticated
  using (
    company_id = (select public.current_company_id())
    and (
      (select public.get_my_role()) = 'owner'
      or salesman_id = (select auth.uid())
    )
  );

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
  where company_id = v_company_id
    and salesman_id = p_salesman_id
    and route_date <= v_today
  order by route_date desc
  limit 1
  for update;

  if found and jsonb_array_length(coalesce(v_active.customer_ids, '[]'::jsonb)) > 0 then
    insert into public.salesman_route_queue (
      company_id, salesman_id, locations, customer_ids, queued_by
    ) values (
      v_company_id, p_salesman_id, coalesce(p_locations, '{}'::text[]),
      p_customer_ids, auth.uid()
    );
    return 'queued';
  end if;

  insert into public.salesman_daily_route_selections (
    company_id, salesman_id, route_date, locations, customer_ids
  ) values (
    v_company_id, p_salesman_id, v_today, coalesce(p_locations, '{}'::text[]), p_customer_ids
  ) on conflict (salesman_id, route_date) do update
  set company_id = excluded.company_id,
      locations = excluded.locations,
      customer_ids = excluded.customer_ids,
      updated_at = now();
  return 'active';
end;
$$;

create or replace function public.activate_next_salesman_route(
  p_salesman_id uuid,
  p_allow_owner boolean default false
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
  if auth.uid() is null then
    raise exception 'You must be logged in.';
  end if;
  if p_allow_owner then
    if public.get_my_role() <> 'owner' then
      raise exception 'Only an owner can remove another salesman route.';
    end if;
  elsif auth.uid() <> p_salesman_id or public.get_my_role() <> 'salesman' then
    raise exception 'You can only finish your own route.';
  end if;
  if v_company_id is null then
    raise exception 'Your account is not linked to a company.';
  end if;
  if not exists (
    select 1 from public.company_members
    where company_id = v_company_id and user_id = p_salesman_id and role = 'salesman'
  ) then
    raise exception 'The selected user is not a salesman in this business.';
  end if;

  select * into v_next
  from public.salesman_route_queue
  where company_id = v_company_id and salesman_id = p_salesman_id
  order by created_at, id
  limit 1
  for update skip locked;

  if found then
    insert into public.salesman_daily_route_selections (
      company_id, salesman_id, route_date, locations, customer_ids
    ) values (
      v_company_id, p_salesman_id, v_today, v_next.locations, v_next.customer_ids
    ) on conflict (salesman_id, route_date) do update
    set company_id = excluded.company_id,
        locations = excluded.locations,
        customer_ids = excluded.customer_ids,
        updated_at = now();
    delete from public.salesman_route_queue where id = v_next.id;
    return 'next_route_activated';
  end if;

  -- An explicit empty assignment prevents an old dated route from becoming
  -- active again through the legacy "latest route on or before today" query.
  insert into public.salesman_daily_route_selections (
    company_id, salesman_id, route_date, locations, customer_ids
  ) values (
    v_company_id, p_salesman_id, v_today, '{}'::text[], '[]'::jsonb
  ) on conflict (salesman_id, route_date) do update
  set company_id = excluded.company_id,
      locations = excluded.locations,
      customer_ids = excluded.customer_ids,
      updated_at = now();
  return 'route_finished';
end;
$$;

revoke all on function public.queue_or_assign_salesman_route(uuid, text[], jsonb) from public, anon;
grant execute on function public.queue_or_assign_salesman_route(uuid, text[], jsonb) to authenticated;
revoke all on function public.activate_next_salesman_route(uuid, boolean) from public, anon;
grant execute on function public.activate_next_salesman_route(uuid, boolean) to authenticated;
