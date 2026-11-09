-- Preserve existing visits and payments while restoring customer-specific
-- assignment IDs for daily rows created before the customer_ids column was
-- populated.
update public.salesman_daily_route_selections as daily
set customer_ids = template.customer_ids
from public.salesman_route_templates as template
where daily.route_date >= current_date
  and jsonb_typeof(coalesce(daily.customer_ids, '[]'::jsonb)) = 'array'
  and jsonb_array_length(coalesce(daily.customer_ids, '[]'::jsonb)) = 0
  and jsonb_typeof(coalesce(template.customer_ids, '[]'::jsonb)) = 'array'
  and jsonb_array_length(coalesce(template.customer_ids, '[]'::jsonb)) > 0
  and daily.locations <@ template.locations
  and template.locations <@ daily.locations;
