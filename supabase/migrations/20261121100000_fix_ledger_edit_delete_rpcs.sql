-- Fix owner edit/delete flows for sales, payments, returns and customers.
--
-- * update_purchase / delete_purchase rejected changes whenever a running
--   balance went below zero, but customer advances (negative balances) have
--   been valid since 20261104150529_allow_customer_payment_advances.  That made
--   many sales impossible to edit or delete.
-- * delete_payment removed the payment but never recalculated the running
--   balances of later entries.
-- * None of these functions checked that the row belongs to the caller's
--   company.
-- * get_customer_signature_paths_for_deletion / delete_customer_permanently were
--   never deployed, so deleting a customer always failed.

create or replace function public.recalculate_customer_ledger(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_opening numeric;
begin
  select coalesce(opening_balance, 0) into v_opening
  from public.customers where id = p_customer_id;
  if not found then return; end if;

  with ordered as (
    select id,
      round(v_opening + coalesce(sum(case
        when entry_type in ('purchase', 'bounced_check') then amount
        when entry_type in ('payment', 'return') then -amount
        else 0 end) over (order by transaction_date, created_at, id
          rows between unbounded preceding and 1 preceding), 0), 2) as before_balance,
      round(v_opening + coalesce(sum(case
        when entry_type in ('purchase', 'bounced_check') then amount
        when entry_type in ('payment', 'return') then -amount
        else 0 end) over (order by transaction_date, created_at, id
          rows between unbounded preceding and current row), 0), 2) as after_balance
    from public.ledger_entries
    where customer_id = p_customer_id
  )
  update public.ledger_entries as l
  set balance_before = o.before_balance,
      balance_after = o.after_balance
  from ordered o
  where l.id = o.id
    and (l.balance_before is distinct from o.before_balance
      or l.balance_after is distinct from o.after_balance);

  update public.payments as p
  set previous_balance = l.balance_before,
      remaining_balance = l.balance_after
  from public.ledger_entries as l
  where l.customer_id = p_customer_id
    and l.entry_type = 'payment'
    and (p.id = l.id or p.id = l.related_payment_id)
    and (p.previous_balance is distinct from l.balance_before
      or p.remaining_balance is distinct from l.balance_after);
end;
$$;

revoke all on function public.recalculate_customer_ledger(uuid) from public, anon, authenticated;

-- Shared guard: returns the caller's company when they are an owner.
create or replace function public.require_owner_company(p_action text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.current_company_id();
begin
  if auth.uid() is null then raise exception 'You must be logged in.'; end if;
  if coalesce(public.get_my_role(), '') <> 'owner' then
    raise exception 'Only an owner can %.', p_action;
  end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  return v_company_id;
end;
$$;

revoke all on function public.require_owner_company(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Sales (purchases)
-- ---------------------------------------------------------------------------
create or replace function public.update_purchase(
  p_entry_id uuid, p_amount numeric, p_notes text,
  p_transaction_date timestamp with time zone default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.require_owner_company('edit a sale');
  v_entry public.ledger_entries;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Sale amount must be greater than zero.';
  end if;

  select l.* into v_entry
  from public.ledger_entries l
  join public.customers c on c.id = l.customer_id
  where l.id = p_entry_id and l.entry_type = 'purchase' and c.company_id = v_company_id
  for update of l;
  if not found then raise exception 'Sale was not found.'; end if;

  perform 1 from public.customers where id = v_entry.customer_id for update;

  update public.ledger_entries
  set amount = round(p_amount, 2),
      notes = nullif(trim(coalesce(p_notes, '')), ''),
      transaction_date = coalesce(p_transaction_date, transaction_date)
  where id = p_entry_id;

  perform public.recalculate_customer_ledger(v_entry.customer_id);

  select * into v_entry from public.ledger_entries where id = p_entry_id;
  return v_entry;
end;
$$;

create or replace function public.delete_purchase(p_entry_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.require_owner_company('delete a sale');
  v_customer_id uuid;
begin
  select l.customer_id into v_customer_id
  from public.ledger_entries l
  join public.customers c on c.id = l.customer_id
  where l.id = p_entry_id and l.entry_type = 'purchase' and c.company_id = v_company_id
  for update of l;
  if not found then raise exception 'Sale was not found.'; end if;

  perform 1 from public.customers where id = v_customer_id for update;
  delete from public.ledger_entries where id = p_entry_id;
  perform public.recalculate_customer_ledger(v_customer_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------------
create or replace function public.delete_payment(p_payment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.require_owner_company('delete payments');
  v_payment public.payments%rowtype;
begin
  select p.* into v_payment
  from public.payments p
  join public.customers c on c.id = p.customer_id
  where p.id = p_payment_id and c.company_id = v_company_id
  for update of p;
  if not found then raise exception 'Payment was not found.'; end if;
  if coalesce(v_payment.is_bounced, false) then
    raise exception 'A bounced cheque cannot be deleted. Keep the bounced record for audit history.';
  end if;

  perform 1 from public.customers where id = v_payment.customer_id for update;

  update public.salesman_customer_daily_status set payment_id = null where payment_id = p_payment_id;
  delete from public.ledger_entries
  where customer_id = v_payment.customer_id
    and entry_type = 'payment'
    and (id = p_payment_id or related_payment_id = p_payment_id);
  delete from public.payments where id = p_payment_id;

  perform public.recalculate_customer_ledger(v_payment.customer_id);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sales returns
-- ---------------------------------------------------------------------------
create or replace function public.update_return(
  p_entry_id uuid, p_amount numeric, p_notes text, p_transaction_date timestamp with time zone
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_role text := public.get_my_role();
  v_company_id uuid := public.current_company_id();
  v_entry public.ledger_entries;
begin
  if v_user is null or coalesce(v_role, '') not in ('owner', 'salesman') then
    raise exception 'Not authorized.';
  end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Return amount must be greater than zero.';
  end if;

  select l.* into v_entry
  from public.ledger_entries l
  join public.customers c on c.id = l.customer_id
  where l.id = p_entry_id and l.entry_type = 'return' and c.company_id = v_company_id
  for update of l;
  if not found then raise exception 'Sales return was not found.'; end if;
  if v_role = 'salesman' and v_entry.user_id is distinct from v_user then
    raise exception 'You can edit only your own return.';
  end if;

  perform 1 from public.customers where id = v_entry.customer_id for update;

  update public.ledger_entries
  set amount = round(p_amount, 2),
      notes = nullif(trim(coalesce(p_notes, '')), ''),
      transaction_date = coalesce(p_transaction_date, transaction_date)
  where id = p_entry_id;

  perform public.recalculate_customer_ledger(v_entry.customer_id);
  select * into v_entry from public.ledger_entries where id = p_entry_id;
  return v_entry;
end;
$$;

create or replace function public.delete_sales_return(p_entry_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.require_owner_company('delete a sales return');
  v_customer_id uuid;
begin
  select l.customer_id into v_customer_id
  from public.ledger_entries l
  join public.customers c on c.id = l.customer_id
  where l.id = p_entry_id and l.entry_type = 'return' and c.company_id = v_company_id
  for update of l;
  if not found then raise exception 'Sales return was not found.'; end if;

  perform 1 from public.customers where id = v_customer_id for update;
  delete from public.ledger_entries where id = p_entry_id;
  perform public.recalculate_customer_ledger(v_customer_id);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permanent customer deletion (was never deployed)
-- ---------------------------------------------------------------------------
create or replace function public.get_customer_signature_paths_for_deletion(p_customer_id uuid)
returns table (signature_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.require_owner_company('permanently delete a customer');
begin
  if not exists (select 1 from public.customers where id = p_customer_id and company_id = v_company_id) then
    raise exception 'Customer was not found.';
  end if;

  return query
  select distinct paths.path
  from (
    select p.signature_path as path from public.payments p
    where p.customer_id = p_customer_id and nullif(trim(p.signature_path), '') is not null
    union
    select l.signature_path from public.ledger_entries l
    where l.customer_id = p_customer_id and nullif(trim(l.signature_path), '') is not null
  ) paths;
end;
$$;

create or replace function public.delete_customer_permanently(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public.require_owner_company('permanently delete a customer');
begin
  perform 1 from public.customers
  where id = p_customer_id and company_id = v_company_id
  for update;
  if not found then raise exception 'Customer was not found.'; end if;

  update public.salesman_daily_route_selections
  set customer_ids = coalesce((
    select jsonb_agg(value) from jsonb_array_elements(customer_ids) as item(value)
    where item.value #>> '{}' <> p_customer_id::text
  ), '[]'::jsonb)
  where company_id = v_company_id
    and customer_ids @> jsonb_build_array(to_jsonb(p_customer_id::text));

  update public.salesman_route_templates
  set customer_ids = coalesce((
    select jsonb_agg(value) from jsonb_array_elements(customer_ids) as item(value)
    where item.value #>> '{}' <> p_customer_id::text
  ), '[]'::jsonb)
  where company_id = v_company_id
    and customer_ids @> jsonb_build_array(to_jsonb(p_customer_id::text));

  delete from public.salesman_visit_audit
  where status_id in (select id from public.salesman_customer_daily_status where customer_id = p_customer_id);
  delete from public.salesman_customer_daily_status where customer_id = p_customer_id;
  delete from public.ledger_entries where customer_id = p_customer_id;
  delete from public.payments where customer_id = p_customer_id;
  delete from public.ledger_import_batches where customer_id = p_customer_id;
  delete from public.customer_group_members where customer_id = p_customer_id;
  delete from public.customers where id = p_customer_id and company_id = v_company_id;

  insert into public.financial_audit_log (
    company_id, actor_id, event_type, target_table, target_id, previous_values, new_values, request_id
  ) values (
    v_company_id, auth.uid(), 'customer_purged', 'customers', p_customer_id, null, null, null
  );
end;
$$;

revoke all on function public.update_purchase(uuid, numeric, text, timestamp with time zone) from public, anon;
revoke all on function public.delete_purchase(uuid) from public, anon;
revoke all on function public.delete_payment(uuid) from public, anon;
revoke all on function public.update_return(uuid, numeric, text, timestamp with time zone) from public, anon;
revoke all on function public.delete_sales_return(uuid) from public, anon;
revoke all on function public.get_customer_signature_paths_for_deletion(uuid) from public, anon;
revoke all on function public.delete_customer_permanently(uuid) from public, anon;

grant execute on function public.update_purchase(uuid, numeric, text, timestamp with time zone) to authenticated;
grant execute on function public.delete_purchase(uuid) to authenticated;
grant execute on function public.delete_payment(uuid) to authenticated;
grant execute on function public.update_return(uuid, numeric, text, timestamp with time zone) to authenticated;
grant execute on function public.delete_sales_return(uuid) to authenticated;
grant execute on function public.get_customer_signature_paths_for_deletion(uuid) to authenticated;
grant execute on function public.delete_customer_permanently(uuid) to authenticated;
