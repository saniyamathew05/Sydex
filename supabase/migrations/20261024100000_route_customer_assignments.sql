alter table public.salesman_route_templates
  add column if not exists customer_ids jsonb not null default '[]'::jsonb;
alter table public.salesman_daily_route_selections
  add column if not exists customer_ids jsonb not null default '[]'::jsonb;
