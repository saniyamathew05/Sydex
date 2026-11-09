-- Harden privileged functions exposed through PostgREST.
-- SECURITY DEFINER functions run with the owner's privileges, so they must never
-- remain executable by PUBLIC/anon. Each function also keeps its own role check.

-- Customer visit/status recording (salesmen only, checked in the function).
revoke all on function public.record_salesman_customer_status(
  uuid, text, double precision, double precision, double precision, text
) from public, anon;
grant execute on function public.record_salesman_customer_status(
  uuid, text, double precision, double precision, double precision, text
) to authenticated;

-- Payment recording (owner/salesman role is checked in the function).
revoke all on function public.record_payment_with_phone_time(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz
) from public, anon;
grant execute on function public.record_payment_with_phone_time(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz
) to authenticated;

-- Owner-only purchase/return/payment maintenance functions.
revoke all on function public.record_purchase(uuid, numeric, text, timestamptz)
  from public, anon;
grant execute on function public.record_purchase(uuid, numeric, text, timestamptz)
  to authenticated;

revoke all on function public.record_purchase_with_discount(
  uuid, numeric, numeric, text, timestamptz
) from public, anon;
grant execute on function public.record_purchase_with_discount(
  uuid, numeric, numeric, text, timestamptz
) to authenticated;

revoke all on function public.record_return(uuid, numeric, text, timestamptz)
  from public, anon;
grant execute on function public.record_return(uuid, numeric, text, timestamptz)
  to authenticated;

revoke all on function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamptz
) from public, anon;
grant execute on function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamptz
) to authenticated;

revoke all on function public.update_purchase(
  uuid, numeric, text, timestamptz
) from public, anon;
grant execute on function public.update_purchase(
  uuid, numeric, text, timestamptz
) to authenticated;

revoke all on function public.delete_purchase(uuid) from public, anon;
grant execute on function public.delete_purchase(uuid) to authenticated;

revoke all on function public.record_bounced_cheque(
  uuid, numeric, text, timestamptz, boolean
) from public, anon;
grant execute on function public.record_bounced_cheque(
  uuid, numeric, text, timestamptz, boolean
) to authenticated;

-- Balance reads are restricted to signed-in application roles.
create or replace function public.get_customer_balances()
returns table(customer_id uuid, balance numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
    round(
      c.opening_balance + coalesce(sum(case
        when l.entry_type = 'purchase' then l.amount
        when l.entry_type in ('payment', 'return') then -l.amount
        when l.entry_type = 'bounced_check' then l.amount
        else 0
      end), 0), 2
    ) as balance
  from public.customers c
  left join public.ledger_entries l on l.customer_id = c.id
  where c.is_active = true
    and (select public.get_my_role()) in ('owner', 'salesman')
  group by c.id, c.opening_balance
$$;
revoke all on function public.get_customer_balances() from public, anon;
grant execute on function public.get_customer_balances() to authenticated;

-- Explicitly keep the name lookup helper authenticated-only.
revoke all on function public.get_payment_receiver_names(uuid[]) from public, anon;
grant execute on function public.get_payment_receiver_names(uuid[]) to authenticated;

-- Pin the search path for every privileged function so caller-controlled schemas
-- cannot shadow objects during SECURITY DEFINER execution.
alter function public.record_salesman_customer_status(
  uuid, text, double precision, double precision, double precision, text
) set search_path = '';
alter function public.record_payment_with_phone_time(
  uuid, numeric, numeric, text, text, timestamptz, text, text, timestamptz
) set search_path = '';
alter function public.record_purchase(uuid, numeric, text, timestamptz)
  set search_path = '';
alter function public.record_purchase_with_discount(
  uuid, numeric, numeric, text, timestamptz
) set search_path = '';
alter function public.record_return(uuid, numeric, text, timestamptz)
  set search_path = '';
alter function public.update_payment(
  uuid, numeric, numeric, text, text, text, timestamptz
) set search_path = '';
alter function public.update_purchase(uuid, numeric, text, timestamptz)
  set search_path = '';
alter function public.delete_purchase(uuid) set search_path = '';
alter function public.record_bounced_cheque(
  uuid, numeric, text, timestamptz, boolean
) set search_path = '';
alter function public.get_customer_balances() set search_path = '';
alter function public.get_payment_receiver_names(uuid[]) set search_path = '';
