create or replace function public.get_payment_receiver_names(p_user_ids uuid[])
returns table (user_id uuid, name text)
language sql
stable
security definer
set search_path = public
as $$
  select profile.id, nullif(trim(profile.name), '')
  from public.profiles as profile
  where auth.uid() is not null
    and public.get_my_role() in ('owner', 'salesman')
    and profile.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and exists (
      select 1
      from public.payments as payment
      where payment.user_id = profile.id
    )
  order by profile.name;
$$;

revoke all on function public.get_payment_receiver_names(uuid[]) from public;
grant execute on function public.get_payment_receiver_names(uuid[]) to authenticated;
