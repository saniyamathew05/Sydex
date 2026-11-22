-- Owners can edit every entry; salesmen can record payments/returns and change
-- the date of entries for customers on their route. Also closes cross-company
-- gaps in older RPCs now that new businesses can register.

-- ---------------------------------------------------------------------------
-- Change the date of any ledger entry (sale, payment, return, bounced cheque)
-- ---------------------------------------------------------------------------
create or replace function public.update_entry_date(
  p_entry_id uuid, p_transaction_date timestamp with time zone
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_role text := public.get_my_role();
  v_company_id uuid := public.current_company_id();
  v_entry public.ledger_entries%rowtype;
begin
  if v_user is null or coalesce(v_role, '') not in ('owner', 'salesman') then
    raise exception 'Not authorized.';
  end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  if p_transaction_date is null then raise exception 'Choose a date.'; end if;

  select l.* into v_entry
  from public.ledger_entries l
  join public.customers c on c.id = l.customer_id
  where l.id = p_entry_id and c.company_id = v_company_id
  for update of l;
  if not found then raise exception 'Entry was not found.'; end if;

  if v_role = 'salesman'
     and v_entry.user_id is distinct from v_user
     and not public.salesman_can_access_customer(v_entry.customer_id) then
    raise exception 'You can change dates only for customers on your route.';
  end if;

  perform 1 from public.customers where id = v_entry.customer_id for update;

  update public.ledger_entries set transaction_date = p_transaction_date where id = p_entry_id;
  if v_entry.entry_type = 'payment' then
    update public.payments
    set transaction_date = p_transaction_date
    where id = coalesce(v_entry.related_payment_id, v_entry.id);
  end if;

  perform public.recalculate_customer_ledger(v_entry.customer_id);
  return true;
end;
$$;

create or replace function public.update_payment_date(p_payment_id uuid, p_transaction_date timestamp with time zone)
returns boolean
language sql
security definer
set search_path = ''
as $$ select public.update_entry_date(p_payment_id, p_transaction_date) $$;

create or replace function public.update_return_date(p_entry_id uuid, p_transaction_date timestamp with time zone)
returns boolean
language sql
security definer
set search_path = ''
as $$ select public.update_entry_date(p_entry_id, p_transaction_date) $$;

-- ---------------------------------------------------------------------------
-- Sales returns: company scoped, salesman route scoped, excess becomes credit
-- ---------------------------------------------------------------------------
create or replace function public.record_return(
  p_customer_id uuid, p_amount numeric, p_notes text,
  p_transaction_date timestamp with time zone default now()
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
    raise exception 'You do not have permission to record a return.';
  end if;
  if v_company_id is null then raise exception 'Your account is not linked to a company.'; end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Return amount must be greater than zero.';
  end if;

  perform 1 from public.customers
  where id = p_customer_id and company_id = v_company_id and is_active = true
  for update;
  if not found then raise exception 'Customer was not found.'; end if;

  if v_role = 'salesman' and not public.salesman_can_access_customer(p_customer_id) then
    raise exception 'This customer is not on your route.';
  end if;

  insert into public.ledger_entries (
    customer_id, company_id, user_id, entry_type, amount, discount, amount_received,
    balance_before, balance_after, transaction_date, notes
  ) values (
    p_customer_id, v_company_id, v_user, 'return', round(p_amount, 2), 0, 0,
    0, 0, coalesce(p_transaction_date, now()), nullif(trim(coalesce(p_notes, '')), '')
  ) returning * into v_entry;

  perform public.recalculate_customer_ledger(p_customer_id);
  select * into v_entry from public.ledger_entries where id = v_entry.id;
  return v_entry;
end;
$$;

-- ---------------------------------------------------------------------------
-- Customer phone: company scoped (salesmen limited to their route)
-- ---------------------------------------------------------------------------
create or replace function public.update_customer_phone(p_customer_id uuid, p_phone text)
returns setof public.customers
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_phone text := btrim(p_phone);
  v_role text := public.get_my_role();
  v_company_id uuid := public.current_company_id();
begin
  if auth.uid() is null or coalesce(v_role, '') not in ('owner', 'salesman') or v_company_id is null then
    raise exception 'Not authorized';
  end if;
  if clean_phone is null or length(clean_phone) > 40 or clean_phone !~ '^[+0-9 ()-]+$'
     or length(regexp_replace(clean_phone, '[^0-9]', '', 'g')) not between 7 and 15 then
    raise exception 'Enter a valid phone number (7-15 digits)';
  end if;
  if v_role = 'salesman' and not public.salesman_can_access_customer(p_customer_id) then
    raise exception 'This customer is not on your route.';
  end if;
  return query
  update public.customers c set phone = clean_phone
  where c.id = p_customer_id and c.is_active = true and c.company_id = v_company_id
  returning c.*;
  if not found then raise exception 'Active customer not found'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Add company checks to older RPCs without rewriting their bodies.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.record_bounced_cheque(uuid, numeric, text, timestamp with time zone, boolean)'::regprocedure);
  v_new := regexp_replace(
    v_def,
    'where id = p_payment_id\s+for update;',
    'where id = p_payment_id and customer_id in (select c.id from public.customers c where c.company_id = public.current_company_id()) for update;'
  );
  if position('current_company_id' in v_new) = 0 then
    raise exception 'record_bounced_cheque guard could not be applied';
  end if;
  execute v_new;

  v_def := pg_get_functiondef('public.import_old_card_transactions(uuid, jsonb)'::regprocedure);
  v_new := regexp_replace(
    v_def,
    'where id = p_customer_id and is_active = true\s+for update;',
    'where id = p_customer_id and is_active = true and company_id = public.current_company_id() for update;'
  );
  if position('current_company_id' in v_new) = 0 then
    raise exception 'import_old_card_transactions guard could not be applied';
  end if;
  execute v_new;
end $$;

revoke all on function public.update_entry_date(uuid, timestamp with time zone) from public, anon;
revoke all on function public.update_payment_date(uuid, timestamp with time zone) from public, anon;
revoke all on function public.update_return_date(uuid, timestamp with time zone) from public, anon;
revoke all on function public.record_return(uuid, numeric, text, timestamp with time zone) from public, anon;
revoke all on function public.update_customer_phone(uuid, text) from public, anon;
grant execute on function public.update_entry_date(uuid, timestamp with time zone) to authenticated;
grant execute on function public.update_payment_date(uuid, timestamp with time zone) to authenticated;
grant execute on function public.update_return_date(uuid, timestamp with time zone) to authenticated;
grant execute on function public.record_return(uuid, numeric, text, timestamp with time zone) to authenticated;
grant execute on function public.update_customer_phone(uuid, text) to authenticated;
