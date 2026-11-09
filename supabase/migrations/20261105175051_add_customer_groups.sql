-- Customer Groups are tenant-scoped labels. They never alter customer
-- balances or financial records; membership is represented only by this join.
create table if not exists public.customer_groups (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 80),
  is_archived boolean not null default false,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, name)
);

create table if not exists public.customer_group_members (
  group_id uuid not null references public.customer_groups(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (group_id, customer_id)
);

create index if not exists customer_groups_company_active_idx
  on public.customer_groups (company_id, is_archived, name);
create index if not exists customer_group_members_customer_idx
  on public.customer_group_members (customer_id, group_id);

alter table public.customer_groups enable row level security;
alter table public.customer_group_members enable row level security;

create policy "Company members can view customer groups"
  on public.customer_groups for select to authenticated
  using (company_id = (select public.current_company_id()));

create policy "Owners manage customer groups"
  on public.customer_groups for all to authenticated
  using (
    company_id = (select public.current_company_id())
    and exists (
      select 1 from public.company_members cm
      where cm.company_id = customer_groups.company_id
        and cm.user_id = (select auth.uid())
        and cm.role = 'owner'
    )
  )
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

create policy "Company members can view customer group memberships"
  on public.customer_group_members for select to authenticated
  using (
    exists (
      select 1 from public.customer_groups cg
      where cg.id = customer_group_members.group_id
        and cg.company_id = (select public.current_company_id())
    )
  );

create policy "Owners manage customer group memberships"
  on public.customer_group_members for all to authenticated
  using (
    exists (
      select 1 from public.customer_groups cg
      join public.company_members cm on cm.company_id = cg.company_id
      where cg.id = customer_group_members.group_id
        and cg.company_id = (select public.current_company_id())
        and cm.user_id = (select auth.uid())
        and cm.role = 'owner'
    )
  )
  with check (
    exists (
      select 1 from public.customer_groups cg
      join public.company_members cm on cm.company_id = cg.company_id
      join public.customers c on c.id = customer_group_members.customer_id
      where cg.id = customer_group_members.group_id
        and cg.company_id = (select public.current_company_id())
        and c.company_id = cg.company_id
        and cm.user_id = (select auth.uid())
        and cm.role = 'owner'
    )
  );
