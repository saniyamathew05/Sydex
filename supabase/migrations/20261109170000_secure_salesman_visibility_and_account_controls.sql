-- Security controls for route visibility, workspace-wide ledger hiding and
-- self-service account removal. Additive only; no existing business rows are
-- modified by this migration.

create or replace function public.salesman_can_access_customer(p_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.salesman_daily_route_selections r
      on r.company_id = p.company_id
     and r.salesman_id = p.id
     and r.route_date <= (timezone('Asia/Kolkata', now()))::date
    where p.id = auth.uid()
      and p.role = 'salesman'
      and exists (
        select 1
        from jsonb_array_elements_text(coalesce(r.customer_ids, '[]'::jsonb)) ids(value)
        where ids.value = p_customer_id::text
      )
  );
$$;

revoke all on function public.salesman_can_access_customer(uuid) from public, anon;
grant execute on function public.salesman_can_access_customer(uuid) to authenticated;

drop policy if exists "Salesmen can view customers in company" on public.customers;
create policy "Salesmen can view assigned route customers"
  on public.customers for select to authenticated
  using (
    company_id = (select public.current_company_id())
    and (
      (select public.get_my_role()) = 'owner'
      or ((select public.get_my_role()) = 'salesman'
          and public.salesman_can_access_customer(id))
    )
  );

drop policy if exists "Company users can view payments" on public.payments;
create policy "Company users can view route payments"
  on public.payments for select to authenticated
  using (
    (company_id = (select public.current_company_id())
      or (company_id is null and exists (
        select 1 from public.customers c
        where c.id = payments.customer_id
          and c.company_id = (select public.current_company_id())
      )))
    and (
      (select public.get_my_role()) = 'owner'
      or ((select public.get_my_role()) = 'salesman'
          and public.salesman_can_access_customer(customer_id))
    )
  );

alter table public.financial_audit_log
  drop constraint if exists financial_audit_log_event_type_check;
alter table public.financial_audit_log
  add constraint financial_audit_log_event_type_check check (event_type = any (array[
    'payment_created','payment_updated','payment_deleted','payment_hidden','payment_unhidden',
    'ledger_entry_created','ledger_entry_updated','ledger_entry_deleted'
  ]));

create or replace function public.set_payment_hidden_from_ledger(
  p_payment_id uuid,
  p_hidden boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid := public.current_company_id();
  v_payment public.payments%rowtype;
begin
  if auth.uid() is null or public.get_my_role() <> 'owner' then
    raise exception 'Only an owner can hide or restore ledger payments.';
  end if;
  select * into v_payment
  from public.payments
  where id = p_payment_id and company_id = v_company_id
  for update;
  if not found then raise exception 'Payment was not found in your workspace.'; end if;
  if v_payment.hidden_from_ledger is distinct from p_hidden then
    update public.payments set hidden_from_ledger = p_hidden where id = p_payment_id;
    insert into public.financial_audit_log(
      company_id, actor_id, event_type, target_table, target_id, previous_values, new_values
    ) values (
      v_company_id, auth.uid(),
      case when p_hidden then 'payment_hidden' else 'payment_unhidden' end,
      'payments', p_payment_id,
      jsonb_build_object('hidden_from_ledger', v_payment.hidden_from_ledger),
      jsonb_build_object('hidden_from_ledger', p_hidden)
    );
  end if;
  return true;
end;
$$;

revoke all on function public.set_payment_hidden_from_ledger(uuid, boolean) from public, anon;
grant execute on function public.set_payment_hidden_from_ledger(uuid, boolean) to authenticated;

-- Self-service deletion is intentionally limited to Salesman accounts. Their
-- historical financial rows remain, but actor/user references are anonymised.
-- Owners must transfer business ownership or contact support before deletion.
alter table public.payments alter column user_id drop not null;
alter table public.ledger_entries alter column user_id drop not null;
alter table public.salesman_customer_daily_status alter column entered_by drop not null;
alter table public.salesman_daily_routes alter column user_id drop not null;

create or replace function public.prepare_my_account_deletion()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_role text;
begin
  select role into v_role from public.profiles where id = v_uid;
  if v_uid is null then raise exception 'You must be signed in.'; end if;
  if v_role <> 'salesman' then
    raise exception 'Owner accounts require business ownership transfer before deletion.';
  end if;
  update public.payments set user_id = null where user_id = v_uid;
  update public.ledger_entries set user_id = null where user_id = v_uid;
  update public.salesman_customer_daily_status set entered_by = null where entered_by = v_uid;
  update public.salesman_daily_routes set user_id = null where user_id = v_uid;
  delete from public.company_members where user_id = v_uid;
  delete from public.profiles where id = v_uid;
  return true;
end;
$$;

revoke all on function public.prepare_my_account_deletion() from public, anon;
grant execute on function public.prepare_my_account_deletion() to authenticated;
