-- Shared business subscriptions. Purchase rows are written only by a trusted
-- provider verification worker (service role), while clients can read the
-- derived entitlement through the authenticated RPC below.
create table if not exists public.subscription_purchases (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  provider text not null default 'google_play' check (provider = 'google_play'),
  platform text not null default 'android' check (platform = 'android'),
  product_id text not null,
  purchase_token text not null,
  order_id text,
  status text not null check (status in ('verified', 'expired', 'revoked', 'in_grace_period', 'on_hold', 'pending')),
  plan_code text not null check (plan_code in ('monthly', 'yearly')),
  base_plan_id text not null check (base_plan_id in ('monthly', 'yearly')),
  trial_ends_at timestamptz,
  canceled_at timestamptz,
  acknowledged_at timestamptz,
  last_reconciled_at timestamptz,
  notification_type text,
  purchased_at timestamptz,
  renews_at timestamptz,
  verified_at timestamptz,
  provider_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, purchase_token)
);

create index if not exists subscription_purchases_company_status_idx
  on public.subscription_purchases (company_id, status, renews_at desc);

create unique index if not exists subscription_purchases_one_active_idx
  on public.subscription_purchases (company_id)
  where status in ('verified', 'in_grace_period', 'on_hold');

alter table public.subscription_purchases enable row level security;

create policy "Workspace members can view subscription status"
  on public.subscription_purchases for select to authenticated
  using (company_id = (select public.current_company_id()));

revoke all on public.subscription_purchases from anon, authenticated;
grant select on public.subscription_purchases to authenticated;

create or replace function public.get_my_subscription_entitlement()
returns table(
  company_id uuid,
  plan_code text,
  status text,
  renews_at timestamptz,
  provider text,
  platform text,
  can_manage_billing boolean,
  paywall_enabled boolean
)
language sql stable security invoker
set search_path = public
as $$
  select
    cm.company_id,
    coalesce(sp.plan_code, 'free') as plan_code,
    case
      when sp.id is null then 'inactive'
      when sp.status = 'verified' and (sp.renews_at is null or sp.renews_at > now()) then 'active'
      else sp.status
    end as status,
    sp.renews_at,
    sp.provider,
    sp.platform,
    (cm.role = 'owner') as can_manage_billing,
    false as paywall_enabled
  from public.company_members cm
  left join lateral (
    select p.*
    from public.subscription_purchases p
    where p.company_id = cm.company_id
      and p.status in ('verified', 'in_grace_period')
      and (p.renews_at is null or p.renews_at > now())
    order by p.renews_at desc nulls last, p.verified_at desc nulls last
    limit 1
  ) sp on true
  where cm.user_id = (select auth.uid())
  limit 1;
$$;

revoke all on function public.get_my_subscription_entitlement() from public, anon;
grant execute on function public.get_my_subscription_entitlement() to authenticated;
