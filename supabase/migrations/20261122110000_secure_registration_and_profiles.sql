-- Registration + account hardening.
--
-- 1. register_company now creates the owner's profile in the same transaction.
--    Previously the app inserted the profile itself, which RLS rejected, so a
--    new owner was left with a company but no profile and could not retry.
-- 2. Users could UPDATE every column of their own profile, including `role`,
--    so a salesman could promote themselves to owner. Only `name` is now
--    writable by the client; role/company changes go through the
--    service-role create-user function.
-- 3. Salesmen could write their own daily route rows, bypassing the owner's
--    route queue. Route rows are now owner-managed; salesmen read their own
--    and finish routes through activate_next_salesman_route.
-- 4. Payments and ledger rows can only be written through the audited RPCs.
-- 5. Unused legacy financial RPCs are no longer callable from the app API.

drop function if exists public.register_company(text);

create or replace function public.register_company(p_name text, p_owner_name text default null)
returns public.companies
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_company public.companies;
  v_member public.company_members%rowtype;
  v_owner_name text;
begin
  if v_uid is null then raise exception 'You must be signed in.'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Company name is required.'; end if;
  if length(trim(p_name)) > 120 then raise exception 'Company name is too long.'; end if;

  v_owner_name := coalesce(
    nullif(trim(p_owner_name), ''),
    nullif(trim((select raw_user_meta_data ->> 'name' from auth.users where id = v_uid)), ''),
    'Owner'
  );

  select * into v_member from public.company_members where user_id = v_uid limit 1;
  if found then
    -- Allow an owner whose earlier registration stopped before the profile
    -- was created to finish it. Anyone else already belongs to a company.
    if v_member.role <> 'owner' or exists (select 1 from public.profiles where id = v_uid) then
      raise exception 'This account already belongs to a company.';
    end if;
    select * into v_company from public.companies where id = v_member.company_id;
  else
    insert into public.companies (name, created_by)
    values (trim(p_name), v_uid)
    returning * into v_company;
    insert into public.company_members (company_id, user_id, role)
    values (v_company.id, v_uid, 'owner');
  end if;

  insert into public.profiles (id, name, role, company_id)
  values (v_uid, left(v_owner_name, 120), 'owner', v_company.id)
  on conflict (id) do update
  set name = excluded.name, role = 'owner', company_id = excluded.company_id;

  return v_company;
end;
$$;

revoke all on function public.register_company(text, text) from public, anon;
grant execute on function public.register_company(text, text) to authenticated;

-- Profiles: only the display name is client-editable.
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (name) on public.profiles to authenticated;

-- Daily routes: owners manage, salesmen read their own.
drop policy if exists "Company users manage daily route selections" on public.salesman_daily_route_selections;
drop policy if exists "Owners manage daily route selections" on public.salesman_daily_route_selections;
drop policy if exists "Salesmen read own daily route selections" on public.salesman_daily_route_selections;

create policy "Owners manage daily route selections"
  on public.salesman_daily_route_selections for all to authenticated
  using (company_id = (select public.current_company_id()) and (select public.get_my_role()) = 'owner')
  with check (company_id = (select public.current_company_id()) and (select public.get_my_role()) = 'owner');

create policy "Salesmen read own daily route selections"
  on public.salesman_daily_route_selections for select to authenticated
  using (company_id = (select public.current_company_id()) and salesman_id = (select auth.uid()));

-- Financial rows are written only by the SECURITY DEFINER RPCs.
revoke insert, update, delete on public.payments from anon, authenticated;
revoke insert, update, delete on public.ledger_entries from anon, authenticated;
revoke insert, update, delete on public.financial_audit_log from anon, authenticated;
revoke insert, update, delete on public.company_members from anon, authenticated;
revoke insert, update, delete on public.companies from anon, authenticated;

-- Legacy RPCs replaced by record_payment_idempotent / record_purchase_with_discount.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('record_payment', 'record_purchase', 'record_payment_with_phone_time')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
