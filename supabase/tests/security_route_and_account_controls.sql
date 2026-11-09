-- Read-only security regression test. Run against a disposable Supabase project
-- with two owner/salesman fixture companies. The script never commits data.
begin;

do $$
declare
  c1 uuid; c2 uuid; s1 uuid; s2 uuid; customer1 uuid; payment1 uuid;
begin
  select company_id into c1 from public.company_members where role='owner' limit 1;
  select company_id into c2 from public.company_members where role='owner' and company_id <> c1 limit 1;
  if c1 is null or c2 is null then
    raise exception 'FAIL: two fixture companies are required';
  end if;
  select user_id into s1 from public.company_members where company_id=c1 and role='salesman' limit 1;
  select user_id into s2 from public.company_members where company_id=c2 and role='salesman' limit 1;
  if s1 is null or s2 is null then raise exception 'FAIL: two salesman fixtures are required'; end if;

  select id into customer1 from public.customers where company_id=c1 limit 1;
  if customer1 is null then raise exception 'FAIL: company 1 customer fixture is required'; end if;
  select id into payment1 from public.payments where company_id=c1 limit 1;
  if payment1 is null then raise exception 'FAIL: company 1 payment fixture is required'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', s2, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.customers where id=customer1) then
    raise exception 'FAIL: cross-company customer read succeeded';
  end if;
  if exists (select 1 from public.payments where id=payment1) then
    raise exception 'FAIL: cross-company payment read succeeded';
  end if;
  begin
    update public.payment_settings set upi_id='blocked@example' where company_id=c1;
    if found then raise exception 'FAIL: salesman changed payment_settings'; end if;
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: cross-company reads and salesman payment_settings write are blocked';
end;
$$;

rollback;
