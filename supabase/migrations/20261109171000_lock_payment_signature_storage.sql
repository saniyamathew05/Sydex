-- Remove broad legacy policies and keep payment signatures private.
drop policy if exists "Authenticated users can upload payment signatures" on storage.objects;
drop policy if exists "Authenticated users can upload signatures vkcijm_0" on storage.objects;
drop policy if exists "Authenticated users can view payment signatures" on storage.objects;
drop policy if exists "Owners can view signatures vkcijm_0" on storage.objects;
drop policy if exists "Users can upload their own signatures vkcijm_0" on storage.objects;
drop policy if exists "Owners can delete payment signatures" on storage.objects;

create policy "Workspace users upload own payment signatures"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'payment-signatures'
    and (select public.get_my_role()) in ('owner','salesman')
    and (storage.foldername(name))[1] = (auth.uid())::text
    and (select public.current_company_id()) is not null
  );

create policy "Workspace users view company payment signatures"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'payment-signatures'
    and exists (
      select 1 from public.payments p
      where p.company_id = (select public.current_company_id())
        and p.signature_path = storage.objects.name
    )
  );

create policy "Owners delete company payment signatures"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'payment-signatures'
    and (select public.get_my_role()) = 'owner'
    and exists (
      select 1 from public.payments p
      where p.company_id = (select public.current_company_id())
        and p.signature_path = storage.objects.name
    )
  );
