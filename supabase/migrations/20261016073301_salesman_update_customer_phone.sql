-- Allow contact-number edits without granting salesmen general customer updates.
create or replace function public.update_customer_phone(p_customer_id uuid, p_phone text)
returns setof public.customers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  clean_phone text := btrim(p_phone);
begin
  if auth.uid() is null or coalesce(public.get_my_role(), '') not in ('owner', 'salesman') then
    raise exception 'Not authorized';
  end if;
  if clean_phone is null or length(clean_phone) > 40
      or clean_phone !~ '^[+0-9 ()-]+$'
      or length(regexp_replace(clean_phone, '[^0-9]', '', 'g')) not between 7 and 15 then
    raise exception 'Enter a valid phone number (7-15 digits)';
  end if;
  return query
    update public.customers c
    set phone = clean_phone
    where c.id = p_customer_id and c.is_active = true
    returning c.*;
  if not found then
    raise exception 'Active customer not found';
  end if;
end;
$$;
revoke all on function public.update_customer_phone(uuid, text) from public, anon;
grant execute on function public.update_customer_phone(uuid, text) to authenticated;
