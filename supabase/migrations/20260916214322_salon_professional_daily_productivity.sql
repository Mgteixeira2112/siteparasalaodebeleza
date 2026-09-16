-- Read-only operational indicators. Completion date is the actual status event in the unit's timezone.
-- Historical completions without accrual are explicitly flagged, never treated as commission zero.
create view public.salon_professional_daily_productivity
with (security_invoker = true)
as
with completion_events as (
  select e.organization_id, e.appointment_id, min(e.occurred_at) as completed_at
  from public.salon_appointment_events e
  where e.event_type = 'status_changed' and e.new_status = 'completed'
  group by e.organization_id, e.appointment_id
)
select
  a.organization_id,
  a.unit_id,
  a.professional_id,
  (ce.completed_at at time zone u.timezone)::date as local_date,
  count(*)::bigint as completed_services,
  sum(a.duration_minutes)::bigint as booked_duration_minutes,
  sum(a.service_price_cents::bigint)::bigint as completed_service_value_cents,
  count(c.appointment_id)::bigint as accrued_service_count,
  count(*) filter (where c.appointment_id is null)::bigint as missing_accrual_count,
  count(*) filter (where c.appointment_id is not null and not c.rule_configured)::bigint as unconfigured_commission_count,
  case when count(*) = count(c.appointment_id)
    then coalesce(sum(c.commission_cents),0)::bigint
    else null::bigint
  end as commission_accrued_cents,
  coalesce(sum(l.commission_cents),0)::bigint as commission_paid_cents,
  case when count(*) = count(c.appointment_id)
    then (coalesce(sum(c.commission_cents),0)-coalesce(sum(l.commission_cents),0))::bigint
    else null::bigint
  end as commission_outstanding_cents
from completion_events ce
join public.salon_appointments a
  on a.organization_id = ce.organization_id and a.id = ce.appointment_id
join public.salon_units u
  on u.organization_id = a.organization_id and u.id = a.unit_id
join public.salon_professionals p
  on p.organization_id = a.organization_id and p.id = a.professional_id
left join public.salon_commission_accruals c
  on c.organization_id = a.organization_id and c.appointment_id = a.id
left join public.salon_commission_payout_lines l
  on l.organization_id = a.organization_id and l.appointment_id = a.id
where a.status = 'completed'
  and (select auth.uid()) is not null
  and (
    salon_private.has_org_role(a.organization_id, array['owner','admin','manager'])
    or exists (
      select 1 from public.salon_members m
      where m.organization_id = a.organization_id
        and m.id = p.member_id
        and m.user_id = (select auth.uid())
        and m.status = 'active'
    )
  )
group by a.organization_id, a.unit_id, a.professional_id,
  (ce.completed_at at time zone u.timezone)::date;

revoke all on public.salon_professional_daily_productivity from public, anon, authenticated;
grant select on public.salon_professional_daily_productivity to authenticated;
comment on view public.salon_professional_daily_productivity is
  'Read-only completed-service value (not cash receipts) and commission metrics by actual completion local date; NULL commission totals indicate missing historical accruals.';