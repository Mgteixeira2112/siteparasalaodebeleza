create or replace view public.salon_client_360
with (security_invoker=true)
as
with appointment_rollup as (
  select
    a.organization_id,
    a.client_id,
    count(*)::bigint as appointment_count,
    count(*) filter (where a.status='completed')::bigint as completed_count,
    count(*) filter (where a.status='cancelled')::bigint as cancelled_count,
    count(*) filter (where a.status='no_show')::bigint as no_show_count,
    count(*) filter (where a.status in ('scheduled','confirmed') and a.starts_at >= clock_timestamp())::bigint as future_booking_count,
    min(a.starts_at) as first_appointment_at,
    max(a.starts_at) as last_appointment_at,
    min(a.starts_at) filter (where a.status in ('scheduled','confirmed') and a.starts_at >= clock_timestamp()) as next_appointment_at,
    coalesce(sum(a.service_price_cents::bigint) filter (where a.status='completed'),0)::bigint as completed_service_value_cents
  from public.salon_appointments a
  group by a.organization_id,a.client_id
),
completion_rollup as (
  select
    a.organization_id,
    a.client_id,
    max(e.occurred_at) as last_completed_at
  from public.salon_appointment_events e
  join public.salon_appointments a
    on a.organization_id=e.organization_id and a.id=e.appointment_id
  where e.event_type='status_changed' and e.new_status='completed'
  group by a.organization_id,a.client_id
),
payment_rollup as (
  select
    c.organization_id,
    c.client_id,
    count(p.id)::bigint as payment_count,
    coalesce(sum(p.amount_cents::bigint),0)::bigint as total_paid_cents,
    max(p.paid_at) as last_payment_at
  from public.salon_comandas c
  join public.salon_payments p
    on p.organization_id=c.organization_id and p.comanda_id=c.id
  where c.client_id is not null
  group by c.organization_id,c.client_id
),
retail_rollup as (
  select
    c.organization_id,
    c.client_id,
    coalesce(sum(r.quantity::bigint),0)::bigint as retail_units_purchased,
    coalesce(sum(r.total_price_cents),0)::bigint as retail_value_cents,
    max(r.created_at) as last_retail_purchase_at
  from public.salon_comandas c
  join public.salon_comanda_retail_items r
    on r.organization_id=c.organization_id and r.comanda_id=c.id
  where c.client_id is not null
  group by c.organization_id,c.client_id
)
select
  cl.organization_id,
  cl.id as client_id,
  cl.full_name,
  cl.phone,
  cl.email,
  cl.status,
  cl.created_at as client_since,
  coalesce(ar.appointment_count,0)::bigint as appointment_count,
  coalesce(ar.completed_count,0)::bigint as completed_count,
  coalesce(ar.cancelled_count,0)::bigint as cancelled_count,
  coalesce(ar.no_show_count,0)::bigint as no_show_count,
  coalesce(ar.future_booking_count,0)::bigint as future_booking_count,
  ar.first_appointment_at,
  ar.last_appointment_at,
  cr.last_completed_at,
  ar.next_appointment_at,
  coalesce(ar.completed_service_value_cents,0)::bigint as completed_service_value_cents,
  coalesce(pr.payment_count,0)::bigint as payment_count,
  coalesce(pr.total_paid_cents,0)::bigint as total_paid_cents,
  pr.last_payment_at,
  coalesce(rr.retail_units_purchased,0)::bigint as retail_units_purchased,
  coalesce(rr.retail_value_cents,0)::bigint as retail_value_cents,
  rr.last_retail_purchase_at
from public.salon_clients cl
left join appointment_rollup ar on ar.organization_id=cl.organization_id and ar.client_id=cl.id
left join completion_rollup cr on cr.organization_id=cl.organization_id and cr.client_id=cl.id
left join payment_rollup pr on pr.organization_id=cl.organization_id and pr.client_id=cl.id
left join retail_rollup rr on rr.organization_id=cl.organization_id and rr.client_id=cl.id;

revoke all on public.salon_client_360 from public,anon,authenticated;
grant select on public.salon_client_360 to authenticated;

create or replace view public.salon_client_timeline
with (security_invoker=true)
as
select
  a.organization_id,
  a.client_id,
  e.occurred_at,
  case
    when e.event_type='created' then 'appointment_created'::text
    when e.event_type='status_changed' then 'appointment_status_changed'::text
    else ('appointment_'||e.event_type)::text
  end as event_type,
  e.id as event_id,
  a.id as appointment_id,
  null::uuid as comanda_id,
  null::bigint as amount_cents,
  jsonb_build_object(
    'old_status',e.old_status,
    'new_status',e.new_status,
    'appointment_source',e.appointment_source,
    'actor_kind',e.actor_kind,
    'actor_role',e.actor_role,
    'sequence_no',e.sequence_no,
    'details',e.details
  ) as details
from public.salon_appointment_events e
join public.salon_appointments a
  on a.organization_id=e.organization_id and a.id=e.appointment_id
union all
select
  c.organization_id,
  c.client_id,
  p.paid_at as occurred_at,
  'payment_received'::text as event_type,
  p.id as event_id,
  c.appointment_id,
  c.id as comanda_id,
  p.amount_cents::bigint as amount_cents,
  jsonb_build_object('method',p.method,'received_by',p.received_by) as details
from public.salon_payments p
join public.salon_comandas c
  on c.organization_id=p.organization_id and c.id=p.comanda_id
where c.client_id is not null
union all
select
  c.organization_id,
  c.client_id,
  r.created_at as occurred_at,
  'retail_sale'::text as event_type,
  r.id as event_id,
  c.appointment_id,
  c.id as comanda_id,
  r.total_price_cents::bigint as amount_cents,
  jsonb_build_object(
    'inventory_item_id',r.inventory_item_id,
    'description',r.description,
    'quantity',r.quantity,
    'unit_price_cents',r.unit_price_cents
  ) as details
from public.salon_comanda_retail_items r
join public.salon_comandas c
  on c.organization_id=r.organization_id and c.id=r.comanda_id
where c.client_id is not null;

revoke all on public.salon_client_timeline from public,anon,authenticated;
grant select on public.salon_client_timeline to authenticated;
