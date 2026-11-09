-- Historical payments already contain the phone-captured time in
-- transaction_date. Copy that local clock time into created_at while keeping
-- the original created_at calendar date. Keep the paired ledger row in sync.
with repaired_times as (
  select
    id,
    (
      timezone('Asia/Kolkata', created_at)::date
      + timezone('Asia/Kolkata', transaction_date)::time
    ) at time zone 'Asia/Kolkata' as repaired_created_at
  from public.payments
  where timezone('Asia/Kolkata', created_at)::time
    is distinct from timezone('Asia/Kolkata', transaction_date)::time
), updated_payments as (
  update public.payments as payment
  set created_at = repaired_times.repaired_created_at
  from repaired_times
  where payment.id = repaired_times.id
  returning payment.id, payment.created_at
)
update public.ledger_entries as ledger
set created_at = updated_payments.created_at
from updated_payments
where ledger.id = updated_payments.id;
