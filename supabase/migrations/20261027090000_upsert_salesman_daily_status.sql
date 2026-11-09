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
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_status_id uuid;
  v_status_date date := timezone('Asia/Kolkata', now())::date;
begin
  if v_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_user_id and lower(p.role) = 'salesman'
  ) then
    raise exception 'Only a salesman can record a customer visit.';
  end if;

  if p_status not in ('paid', 'rejected') then
    raise exception 'Invalid visit status.';
  end if;

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Latitude and longitude must both be provided.';
  end if;

  insert into public.salesman_customer_daily_status
    (customer_id, status_date, status, entered_by, note)
  values
    (p_customer_id, v_status_date, p_status, v_user_id, nullif(trim(p_note), ''))
  on conflict (customer_id, status_date) do update
    set status = excluded.status,
        entered_by = excluded.entered_by,
        note = excluded.note
  returning id into v_status_id;

  if p_latitude is not null then
    insert into public.salesman_visit_audit
      (status_id, latitude, longitude, accuracy_meters, captured_at)
    values (v_status_id, p_latitude, p_longitude, p_accuracy_meters, now());
  end if;

  return jsonb_build_object('id', v_status_id, 'status', p_status);
end;
$$;

grant execute on function public.record_salesman_customer_status(
  uuid, text, double precision, double precision, double precision, text
) to authenticated;
