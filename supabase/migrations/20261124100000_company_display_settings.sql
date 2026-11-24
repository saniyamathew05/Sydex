-- What salesmen see in the app, chosen by the owner. Presentation only: this
-- does not grant or remove access to any data. Additive, so earlier versions
-- of the app are unaffected.
create table if not exists public.company_display_settings (
  company_id uuid primary key references public.companies(id) on delete cascade,
  salesman jsonb not null default '{}'::jsonb
    check (jsonb_typeof(salesman) = 'object' and pg_column_size(salesman) < 4096),
  updated_at timestamptz not null default now()
);

alter table public.company_display_settings enable row level security;

revoke all on public.company_display_settings from anon, authenticated;
grant select, insert, update on public.company_display_settings to authenticated;

drop policy if exists "Company members read display settings" on public.company_display_settings;
create policy "Company members read display settings"
  on public.company_display_settings for select to authenticated
  using (company_id = (select public.current_company_id()));

drop policy if exists "Owners add display settings" on public.company_display_settings;
create policy "Owners add display settings"
  on public.company_display_settings for insert to authenticated
  with check (company_id = (select public.current_company_id())
    and (select public.get_my_role()) = 'owner');

drop policy if exists "Owners change display settings" on public.company_display_settings;
create policy "Owners change display settings"
  on public.company_display_settings for update to authenticated
  using (company_id = (select public.current_company_id())
    and (select public.get_my_role()) = 'owner')
  with check (company_id = (select public.current_company_id())
    and (select public.get_my_role()) = 'owner');
