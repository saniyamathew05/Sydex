begin;

do $test$
declare
  cid uuid; uid uuid; b numeric; e public.ledger_entries; p public.payments;
begin
  select id into uid from public.profiles where role='owner' limit 1;
  if uid is null then raise exception 'Owner test account missing'; end if;
  perform set_config('request.jwt.claims',json_build_object('sub',uid,'role','authenticated')::text,true);
  insert into public.customers(business_name,location,phone,opening_balance)
    values('__credit_rollback_test__','__test__','9999999999',100) returning id into cid;
  e := public.record_return(cid,200,'Rollback test',now());
  if e.balance_before <> 100 or e.balance_after <> -100 then raise exception 'Return credit incorrect'; end if;
  select balance into b from public.get_customer_balances() where customer_id=cid;
  if b <> -100 then raise exception 'Balance query hides credit'; end if;
  e := public.record_return(cid,50,'Rollback test',now()+interval '1 second');
  if e.balance_after <> -150 then raise exception 'Further return incorrect'; end if;
  e := public.record_purchase(cid,50,'Rollback test',now()+interval '2 seconds');
  if e.balance_before <> -150 or e.balance_after <> -100 then raise exception 'Sale lost credit'; end if;
  e := public.record_purchase_with_discount(cid,200,50,'Rollback test',now()+interval '3 seconds');
  if e.balance_before <> -100 or e.balance_after <> 50 then raise exception 'Discounted sale lost credit'; end if;
  p := public.record_payment_with_phone_time(cid,10,0,'Rollback test',null,now()+interval '4 seconds','cash',null,now());
  if p.remaining_balance <> 40 then raise exception 'Payment balance incorrect'; end if;
  perform public.update_payment(p.id,15,0,'Rollback test','cash',null,p.transaction_date);
  select balance into b from public.get_customer_balances() where customer_id=cid;
  if b <> 35 then raise exception 'Edit with historical return credit failed'; end if;
  perform public.update_purchase(e.id,160,'Rollback test',e.transaction_date);
  select balance into b from public.get_customer_balances() where customer_id=cid;
  if b <> 45 then raise exception 'Sale edit with credit failed'; end if;
  perform public.delete_purchase((select id from public.ledger_entries where customer_id=cid and entry_type='purchase' and amount=50 limit 1));
  -- This deletion would overdraw the later payment, so it must be rejected.
  raise exception 'Expected payment overdraw guard';
exception when others then
  if sqlerrm = 'This purchase cannot be deleted because a historical payment depends on it.' then
    return;
  end if;
  raise;
end $test$;
select 'credit, additional return, sales, payment edits, and overpayment protection passed' as test_result;

do $test$
declare cid uuid; uid uuid; e public.ledger_entries; b numeric;
begin
  select id into uid from public.profiles where role='salesman' limit 1;
  if uid is null then raise exception 'Salesman test account missing'; end if;
  perform set_config('request.jwt.claims',json_build_object('sub',uid,'role','authenticated')::text,true);
  insert into public.customers(business_name,location,phone,opening_balance)
    values('__salesman_credit_rollback_test__','__test__','9999999999',100) returning id into cid;
  e := public.record_return(cid,200,'Rollback test',now());
  if e.balance_after <> -100 then raise exception 'Salesman credit failed'; end if;
  begin
    perform public.record_return(cid,0,'Invalid amount test',now());
    raise exception 'Zero return was accepted';
  exception when others then
    if sqlerrm <> 'Return amount must be greater than zero.' then raise; end if;
  end;
  begin
    perform public.record_payment_with_phone_time(cid,10,0,'Invalid payment test');
    raise exception 'Payment on credit balance accepted';
  exception when others then
    if sqlerrm <> 'Amount to settle cannot be greater than the current balance.' then raise; end if;
  end;
end $test$;
select 'salesman credit and invalid-payment checks passed' as test_result;

rollback;
