do $$
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'salesman_customer_daily_status'
  ) then
    alter publication supabase_realtime
      add table public.salesman_customer_daily_status;
  end if;
end;
$$;
