-- Legacy payments and ledger entries created before company scoping have a
-- null company_id, so company-scoped RPCs (e.g. set_payment_hidden_from_ledger)
-- report "not found" for them. Copy the company from the owning customer.
update public.payments p
set company_id = c.company_id
from public.customers c
where c.id = p.customer_id
  and p.company_id is null
  and c.company_id is not null;

update public.ledger_entries l
set company_id = c.company_id
from public.customers c
where c.id = l.customer_id
  and l.company_id is null
  and c.company_id is not null;
