-- A customer erasure is a deliberate owner-only operation.  It deletes all
-- operational customer records in one database transaction instead of merely
-- hiding the customer from the list.

-- A purge must not preserve a copy of payment or ledger data in the ordinary
-- financial audit payload.  Retain only a non-PII proof that an owner initiated
-- the erasure so support can investigate an accidental deletion without
-- retaining the customer's financial history.
alter table public.financial_audit_log
  drop constraint if exists financial_audit_log_event_type_check;

alter table public.financial_audit_log
  add constraint financial_audit_log_event_type_check
  check (event_type in (
    'payment_created', 'payment_updated', 'payment_deleted',
    'ledger_entry_created', 'ledger_entry_updated', 'ledger_entry_deleted',
    'customer_purged'
  ));

create or replace function public.write_financial_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_target_id uuid;
  v_event_type text;
  v_previous jsonb;
  v_new jsonb;
  v_request_id text;
begin
  -- The controlled customer-erasure endpoint writes one minimal event itself.
  -- Skipping row events here prevents deleted financial values being retained.
  if current_setting('app.horizon_customer_purge', true) = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    v_company_id := old.company_id;
    v_target_id := old.id;
    v_previous := to_jsonb(old);
    v_new := null;
  else
    v_company_id := new.company_id;
    v_target_id := new.id;
    v_previous := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
    v_new := to_jsonb(new);
  end if;

  if tg_table_name = 'payments' then
    v_event_type := case tg_op
      when 'INSERT' then 'payment_created'
      when 'UPDATE' then 'payment_updated'
      else 'payment_deleted'
    end;
    v_request_id := case when tg_op = 'DELETE' then old.idempotency_key else new.idempotency_key end;
  else
    v_event_type := case tg_op
      when 'INSERT' then 'ledger_entry_created'
      when 'UPDATE' then 'ledger_entry_updated'
      else 'ledger_entry_deleted'
    end;
    v_request_id := null;
  end if;

  insert into public.financial_audit_log (
    company_id, actor_id, event_type, target_table, target_id,
    previous_values, new_values, request_id
  ) values (
    v_company_id, auth.uid(), v_event_type, tg_table_name, v_target_id,
    v_previous, v_new, v_request_id
  );
  return coalesce(new, old);
end;
$$;

create or replace function public.get_customer_signature_paths_for_deletion(p_customer_id uuid)
returns table (signature_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_company_id uuid := public.current_company_id();
begin
  if v_actor_id is null or public.get_my_role() <> 'owner' then
    raise exception 'Only an owner can permanently delete a customer.';
  end if;
  if not exists (
    select 1 from public.customers
    where id = p_customer_id and company_id = v_company_id
  ) then
    raise exception 'Customer was not found.';
  end if;

  return query
  select distinct paths.path
  from (
    select p.signature_path as path
    from public.payments p
    where p.customer_id = p_customer_id and nullif(trim(p.signature_path), '') is not null
    union
    select l.signature_path as path
    from public.ledger_entries l
    where l.customer_id = p_customer_id and nullif(trim(l.signature_path), '') is not null
  ) paths;
end;
$$;

revoke all on function public.get_customer_signature_paths_for_deletion(uuid) from public, anon;
grant execute on function public.get_customer_signature_paths_for_deletion(uuid) to authenticated;

create or replace function public.delete_customer_permanently(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_company_id uuid := public.current_company_id();
  v_customer public.customers%rowtype;
begin
  if v_actor_id is null then
    raise exception 'You must be logged in.';
  end if;
  if public.get_my_role() <> 'owner' then
    raise exception 'Only an owner can permanently delete a customer.';
  end if;
  if v_company_id is null then
    raise exception 'Your account is not linked to a company.';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id and company_id = v_company_id
  for update;
  if not found then
    raise exception 'Customer was not found.';
  end if;



  -- Suppress detailed row audit entries inside this transaction.
  perform set_config('app.horizon_customer_purge', 'on', true);

  -- Remove the customer from mixed manual route selections and templates while
  -- preserving every other selected customer.
  update public.salesman_daily_route_selections
  set customer_ids = coalesce((
    select jsonb_agg(value)
    from jsonb_array_elements(customer_ids) as item(value)
    where item.value #>> '{}' <> p_customer_id::text
  ), '[]'::jsonb), updated_at = now()
  where company_id = v_company_id
    and customer_ids @> jsonb_build_array(to_jsonb(p_customer_id::text));

  update public.salesman_route_templates
  set customer_ids = coalesce((
    select jsonb_agg(value)
    from jsonb_array_elements(customer_ids) as item(value)
    where item.value #>> '{}' <> p_customer_id::text
  ), '[]'::jsonb), updated_at = now()
  where company_id = v_company_id
    and customer_ids @> jsonb_build_array(to_jsonb(p_customer_id::text));

  -- Visit-audit rows depend on daily status rows. Delete them explicitly before
  -- statuses, then remove every financial record and import batch.
  delete from public.salesman_visit_audit
  where status_id in (
    select id from public.salesman_customer_daily_status
    where customer_id = p_customer_id
  );

  delete from public.salesman_customer_daily_status
  where customer_id = p_customer_id;

  delete from public.ledger_entries
  where customer_id = p_customer_id;

  delete from public.payments
  where customer_id = p_customer_id;

  delete from public.ledger_import_batches
  where customer_id = p_customer_id;

  delete from public.customer_group_members
  where customer_id = p_customer_id;

  delete from public.customers
  where id = p_customer_id and company_id = v_company_id;

  insert into public.financial_audit_log (
    company_id, actor_id, event_type, target_table, target_id,
    previous_values, new_values, request_id
  ) values (
    v_company_id, v_actor_id, 'customer_purged', 'customers', p_customer_id,
    null, null, null
  );

  return;
end;
$$;

revoke all on function public.delete_customer_permanently(uuid) from public, anon;
grant execute on function public.delete_customer_permanently(uuid) to authenticated;

-- Allow an owner to delete only signature files linked to records in the
-- active workspace. The client removes them before database erasure, so the
-- policy can validate the relationship.
drop policy if exists "Owners can delete payment signatures" on storage.objects;
create policy "Owners can delete payment signatures"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'payment-signatures'
    and (select public.get_my_role()) = 'owner'
    and exists (
      select 1 from public.payments p
      where p.signature_path = name
        and p.company_id = (select public.current_company_id())
      union all
      select 1 from public.ledger_entries l
      where l.signature_path = name
        and l.company_id = (select public.current_company_id())
    )
  );
