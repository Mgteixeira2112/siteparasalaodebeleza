alter table public.salon_appointment_events
  add column sequence_no bigint generated always as identity;

create unique index salon_appointment_events_sequence_uidx
  on public.salon_appointment_events (sequence_no);

drop index if exists public.salon_appointment_events_org_appointment_time_idx;
create index salon_appointment_events_org_appointment_sequence_idx
  on public.salon_appointment_events (organization_id, appointment_id, sequence_no);

revoke all on table public.salon_appointment_events from public, anon, authenticated;
grant select on table public.salon_appointment_events to authenticated;

create or replace function salon_private.reject_appointment_event_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'appointment event history is immutable' using errcode = '55000';
end;
$$;

revoke all on function salon_private.reject_appointment_event_mutation() from public, anon, authenticated;

create trigger salon_appointment_events_immutable
before update or delete on public.salon_appointment_events
for each row execute function salon_private.reject_appointment_event_mutation();