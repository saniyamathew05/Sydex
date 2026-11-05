-- Payment settings use the fixed row id 1 for each company. Scope that id by
-- company so each tenant can safely own its own settings row.
alter table public.payment_settings
  alter column company_id set not null;

alter table public.payment_settings
  drop constraint if exists payment_settings_pkey;

alter table public.payment_settings
  add constraint payment_settings_pkey primary key (id, company_id);
