-- Owner-controlled visibility for payment ledger entries.
-- Hidden entries remain in the database and customer history.
alter table public.payments
  add column if not exists hidden_from_ledger boolean not null default false;

create index if not exists payments_hidden_from_ledger_idx
  on public.payments (hidden_from_ledger);
