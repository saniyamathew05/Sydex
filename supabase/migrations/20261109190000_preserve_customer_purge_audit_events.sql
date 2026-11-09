-- Keep existing customer deletion audit events valid after the ledger audit
-- constraint is extended for hidden/unhidden payments.
alter table public.financial_audit_log
  drop constraint if exists financial_audit_log_event_type_check;

alter table public.financial_audit_log
  add constraint financial_audit_log_event_type_check check (event_type = any (array[
    'payment_created','payment_updated','payment_deleted','payment_hidden','payment_unhidden',
    'ledger_entry_created','ledger_entry_updated','ledger_entry_deleted','customer_purged'
  ]));
