create table public.salon_appointment_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  appointment_id uuid not null,
  event_type text not null check (event_type in ('initial_snapshot','created','status_changed')),
  old_status text,
  new_status text not null,
  appointment_source text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  actor_role text,
  actor_kind text not null check (actor_kind in ('user','public','system')),
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  constraint salon_appointment_events_appointment_same_org_fkey
    foreign key (organization_id, appointment_id)
    references public.salon_appointments(organization_id, id)
    on delete restrict
);

create index salon_appointment_events_org_appointment_time_idx
  on public.salon_appointment_events (organization_id, appointment_id, occurred_at, id);
create index salon_appointment_events_org_time_idx
  on public.salon_appointment_events (organization_id, occurred_at desc, id);
create index salon_appointment_events_actor_idx
  on public.salon_appointment_events (actor_user_id)
  where actor_user_id is not null;

create or replace function salon_private.audit_appointment_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_type text;
  v_old_status text;
  v_actor_id uuid;
  v_actor_role text;
  v_actor_kind text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  v_event_type := case when tg_op = 'INSERT' then 'created' else 'status_changed' end;
  v_old_status := case when tg_op = 'UPDATE' then old.status else null end;
  v_actor_id := auth.uid();

  if v_actor_id is not null then
    select m.role
      into v_actor_role
    from public.salon_members m
    where m.organization_id = new.organization_id
      and m.user_id = v_actor_id
    limit 1;
    v_actor_kind := 'user';
  elsif new.source = 'online' then
    v_actor_kind := 'public';
  else
    v_actor_kind := 'system';
  end if;

  insert into public.salon_appointment_events (
    organization_id,
    appointment_id,
    event_type,
    old_status,
    new_status,
    appointment_source,
    actor_user_id,
    actor_role,
    actor_kind,
    details,
    occurred_at
  ) values (
    new.organization_id,
    new.id,
    v_event_type,
    v_old_status,
    new.status,
    new.source,
    v_actor_id,
    v_actor_role,
    v_actor_kind,
    jsonb_build_object(
      'unit_id', new.unit_id,
      'client_id', new.client_id,
      'service_id', new.service_id,
      'professional_id', new.professional_id,
      'starts_at', new.starts_at,
      'ends_at', new.ends_at,
      'duration_minutes', new.duration_minutes
    ),
    now()
  );

  return new;
end;
$$;

revoke all on function salon_private.audit_appointment_event() from public, anon, authenticated;

insert into public.salon_appointment_events (
  organization_id,
  appointment_id,
  event_type,
  old_status,
  new_status,
  appointment_source,
  actor_user_id,
  actor_role,
  actor_kind,
  details,
  occurred_at
)
select
  a.organization_id,
  a.id,
  'initial_snapshot',
  null,
  a.status,
  a.source,
  null,
  null,
  'system',
  jsonb_build_object(
    'unit_id', a.unit_id,
    'client_id', a.client_id,
    'service_id', a.service_id,
    'professional_id', a.professional_id,
    'starts_at', a.starts_at,
    'ends_at', a.ends_at,
    'duration_minutes', a.duration_minutes
  ),
  a.created_at
from public.salon_appointments a;

create trigger salon_appointments_audit_event
  after insert or update of status on public.salon_appointments
  for each row execute function salon_private.audit_appointment_event();

alter table public.salon_appointment_events enable row level security;

create policy "salon members read appointment events"
on public.salon_appointment_events
for select to authenticated
using (salon_private.is_active_member(organization_id));

grant select on public.salon_appointment_events to authenticated;