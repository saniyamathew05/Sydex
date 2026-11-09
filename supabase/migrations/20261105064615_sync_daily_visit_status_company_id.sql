-- Older visit writes omitted company_id. Company-scoped RLS therefore hid
-- those saved statuses from both the salesman and owner interfaces.
update public.salesman_customer_daily_status as visit
set company_id = customer.company_id
from public.customers as customer
where visit.customer_id = customer.id
  and visit.company_id is null;

-- Keep the status visible to its company on future paid/refused visits.
create or replace function public.record_salesman_customer_status(
  p_customer_id uuid,
  p_status text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_meters double precision default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_company_id uuid;
  v_status_id uuid;
  v_status_date date := timezone('Asia/Kolkata', now())::date;
begin
  if v_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles as profile
  where profile.id = v_user_id
    and lower(btrim(profile.role)) = 'salesman';

  if v_company_id is null then
    raise exception 'Only a salesman linked to a company can record a customer visit.';
  end if;

  if p_status is null or p_status not in ('paid', 'rejected') then
    raise exception 'Invalid visit status.';
  end if;

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Latitude and longitude must both be provided.';
  end if;

  if p_latitude is not null and (
    p_latitude < -90 or p_latitude > 90 or
    p_longitude < -180 or p_longitude > 180
  ) then
    raise exception 'Visit coordinates are outside the valid range.';
  end if;

  if not exists (
    select 1
    from public.customers as customer
    where customer.id = p_customer_id
      and customer.company_id = v_company_id
      and customer.is_active = true
  ) then
    raise exception 'Customer not found in your company.';
  end if;

  insert into public.salesman_customer_daily_status
    (customer_id, company_id, status_date, status, entered_by, note)
  values
    (
      p_customer_id,
      v_company_id,
      v_status_date,
      p_status,
      v_user_id,
      nullif(btrim(p_note), '')
    )
  on conflict (customer_id, status_date) do update
    set company_id = excluded.company_id,
        status = excluded.status,
        entered_by = excluded.entered_by,
        note = excluded.note
  returning id into v_status_id;

  if p_latitude is not null then
    update public.customers
    set latitude = p_latitude,
        longitude = p_longitude
    where id = p_customer_id
      and company_id = v_company_id;

    insert into public.salesman_visit_audit
      (status_id, latitude, longitude, accuracy_meters, captured_at)
    values (v_status_id, p_latitude, p_longitude, p_accuracy_meters, now());
  end if;

  return jsonb_build_object(
    'id', v_status_id,
    'status', p_status,
    'latitude', p_latitude,
    'longitude', p_longitude
  );
end;
$$;
