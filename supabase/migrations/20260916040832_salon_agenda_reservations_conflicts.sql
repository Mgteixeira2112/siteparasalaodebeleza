create table public.salon_clients (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  full_name text not null check (btrim(full_name) <> ''),
  phone text,
  email text,
  status text not null default 'active' check (status in ('active','inactive')),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);

create table public.salon_appointments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  unit_id uuid not null,
  client_id uuid not null,
  service_id uuid not null,
  professional_id uuid not null,
  starts_at timestamptz not null,
  duration_minutes integer not null check (duration_minutes > 0),
  ends_at timestamptz not null,
  slot_range tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  status text not null default 'scheduled' check (
    status in ('scheduled','confirmed','checked_in','in_service','completed','cancelled','no_show')
  ),
  source text not null default 'internal' check (source in ('internal','online','recurrence')),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  constraint salon_appointments_time_check check (starts_at < ends_at),
  constraint salon_appointments_unit_same_org_fkey
    foreign key (organization_id, unit_id)
    references public.salon_units(organization_id, id),
  constraint salon_appointments_client_same_org_fkey
    foreign key (organization_id, client_id)
    references public.salon_clients(organization_id, id),
  constraint salon_appointments_service_same_org_fkey
    foreign key (organization_id, service_id)
    references public.salon_services(organization_id, id),
  constraint salon_appointments_professional_same_org_fkey
    foreign key (organization_id, professional_id)
    references public.salon_professionals(organization_id, id),
  constraint salon_appointments_professional_no_overlap
    exclude using gist (
      organization_id with =,
      professional_id with =,
      slot_range with &&
    ) where (status in ('scheduled','confirmed','checked_in','in_service'))
);

create table public.salon_appointment_resources (
  organization_id uuid not null,
  appointment_id uuid not null,
  resource_id uuid not null,
  starts_at timestamptz not null,
  duration_minutes integer not null check (duration_minutes > 0),
  ends_at timestamptz not null,
  appointment_status text not null,
  slot_range tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  created_at timestamptz not null default now(),
  primary key (organization_id, appointment_id, resource_id),
  constraint salon_appointment_resources_time_check check (starts_at < ends_at),
  constraint salon_appointment_resources_appointment_same_org_fkey
    foreign key (organization_id, appointment_id)
    references public.salon_appointments(organization_id, id) on delete cascade,
  constraint salon_appointment_resources_resource_same_org_fkey
    foreign key (organization_id, resource_id)
    references public.salon_resources(organization_id, id),
  constraint salon_appointment_resources_no_overlap
    exclude using gist (
      organization_id with =,
      resource_id with =,
      slot_range with &&
    ) where (appointment_status in ('scheduled','confirmed','checked_in','in_service'))
);

create index salon_clients_org_status_idx on public.salon_clients (organization_id, status);
create index salon_clients_created_by_idx on public.salon_clients (created_by) where created_by is not null;
create index salon_appointments_org_start_idx on public.salon_appointments (organization_id, starts_at, status);
create index salon_appointments_org_unit_fk_idx on public.salon_appointments (organization_id, unit_id);
create index salon_appointments_org_client_fk_idx on public.salon_appointments (organization_id, client_id);
create index salon_appointments_org_service_fk_idx on public.salon_appointments (organization_id, service_id);
create index salon_appointments_org_professional_fk_idx on public.salon_appointments (organization_id, professional_id);
create index salon_appointments_created_by_idx on public.salon_appointments (created_by) where created_by is not null;
create index salon_appointment_resources_org_resource_fk_idx on public.salon_appointment_resources (organization_id, resource_id);
create index salon_appointment_resources_appointment_idx on public.salon_appointment_resources (appointment_id);

create or replace function salon_private.prepare_appointment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_service_duration integer;
  v_service_status text;
  v_professional_status text;
  v_unit_status text;
  v_unit_timezone text;
  v_client_status text;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_slot_changed boolean;
  v_old_active boolean;
  v_new_active boolean;
begin
  select s.duration_minutes, s.status
    into v_service_duration, v_service_status
  from public.salon_services s
  where s.organization_id = new.organization_id and s.id = new.service_id;
  if not found then
    raise exception 'service does not belong to organization' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' or new.service_id is distinct from old.service_id then
    new.duration_minutes := v_service_duration;
  end if;
  new.ends_at := new.starts_at + new.duration_minutes * interval '1 minute';

  if tg_op = 'INSERT' or new.professional_id is distinct from old.professional_id or new.service_id is distinct from old.service_id then
    if not exists (
      select 1 from public.salon_professional_services ps
      where ps.organization_id = new.organization_id
        and ps.professional_id = new.professional_id
        and ps.service_id = new.service_id
    ) then
      raise exception 'professional is not assigned to service' using errcode = '23514';
    end if;
  end if;

  select p.status into v_professional_status
  from public.salon_professionals p
  where p.organization_id = new.organization_id and p.id = new.professional_id;
  if not found then
    raise exception 'professional does not belong to organization' using errcode = '23514';
  end if;

  select u.status, u.timezone into v_unit_status, v_unit_timezone
  from public.salon_units u
  where u.organization_id = new.organization_id and u.id = new.unit_id;
  if not found then
    raise exception 'unit does not belong to organization' using errcode = '23514';
  end if;

  select c.status into v_client_status
  from public.salon_clients c
  where c.organization_id = new.organization_id and c.id = new.client_id;
  if not found then
    raise exception 'client does not belong to organization' using errcode = '23514';
  end if;

  v_new_active := new.status in ('scheduled','confirmed','checked_in','in_service');
  if tg_op = 'INSERT' then
    v_old_active := false;
    v_slot_changed := true;
  else
    v_old_active := old.status in ('scheduled','confirmed','checked_in','in_service');
    v_slot_changed := new.starts_at is distinct from old.starts_at
      or new.unit_id is distinct from old.unit_id
      or new.professional_id is distinct from old.professional_id
      or new.service_id is distinct from old.service_id
      or new.client_id is distinct from old.client_id
      or (not v_old_active and v_new_active);
  end if;

  if v_new_active and v_slot_changed then
    if v_service_status <> 'active' or v_professional_status <> 'active' or v_unit_status <> 'active' or v_client_status <> 'active' then
      raise exception 'appointment requires active client, service, professional and unit' using errcode = '23514';
    end if;

    v_local_start := new.starts_at at time zone v_unit_timezone;
    v_local_end := new.ends_at at time zone v_unit_timezone;

    if v_local_start::date <> v_local_end::date then
      raise exception 'appointment must fit within one local calendar day' using errcode = '23514';
    end if;

    if not exists (
      select 1
      from public.salon_professional_availability a
      where a.organization_id = new.organization_id
        and a.professional_id = new.professional_id
        and a.unit_id = new.unit_id
        and a.status = 'active'
        and a.weekday = extract(dow from v_local_start)::smallint
        and a.starts_at <= v_local_start::time
        and a.ends_at >= v_local_end::time
    ) then
      raise exception 'appointment is outside professional availability' using errcode = '23514';
    end if;

    if exists (
      select 1
      from public.salon_calendar_blocks b
      where b.organization_id = new.organization_id
        and b.unit_id = new.unit_id
        and b.status = 'active'
        and tstzrange(b.starts_at, b.ends_at, '[)') && tstzrange(new.starts_at, new.ends_at, '[)')
        and (
          (b.professional_id is null and b.resource_id is null)
          or b.professional_id = new.professional_id
        )
    ) then
      raise exception 'appointment conflicts with calendar block' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create or replace function salon_private.prepare_appointment_resource()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_appointment public.salon_appointments%rowtype;
  v_resource_status text;
  v_resource_unit uuid;
begin
  select * into v_appointment
  from public.salon_appointments a
  where a.organization_id = new.organization_id and a.id = new.appointment_id;
  if not found then
    raise exception 'appointment does not belong to organization' using errcode = '23514';
  end if;

  select r.status, r.unit_id into v_resource_status, v_resource_unit
  from public.salon_resources r
  where r.organization_id = new.organization_id and r.id = new.resource_id;
  if not found then
    raise exception 'resource does not belong to organization' using errcode = '23514';
  end if;

  if v_resource_status <> 'active' then
    raise exception 'resource must be active' using errcode = '23514';
  end if;
  if v_resource_unit is not null and v_resource_unit <> v_appointment.unit_id then
    raise exception 'resource belongs to another unit' using errcode = '23514';
  end if;

  new.starts_at := v_appointment.starts_at;
  new.duration_minutes := v_appointment.duration_minutes;
  new.ends_at := v_appointment.ends_at;
  new.appointment_status := v_appointment.status;

  if new.appointment_status in ('scheduled','confirmed','checked_in','in_service') and exists (
    select 1
    from public.salon_calendar_blocks b
    where b.organization_id = new.organization_id
      and b.unit_id = v_appointment.unit_id
      and b.status = 'active'
      and tstzrange(b.starts_at, b.ends_at, '[)') && tstzrange(v_appointment.starts_at, v_appointment.ends_at, '[)')
      and (
        (b.professional_id is null and b.resource_id is null)
        or b.resource_id = new.resource_id
      )
  ) then
    raise exception 'resource conflicts with calendar block' using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function salon_private.sync_appointment_resources()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.starts_at is distinct from old.starts_at
     or new.duration_minutes is distinct from old.duration_minutes
     or new.status is distinct from old.status
     or new.unit_id is distinct from old.unit_id then
    update public.salon_appointment_resources
       set appointment_id = appointment_id
     where organization_id = new.organization_id and appointment_id = new.id;
  end if;
  return new;
end;
$$;

create or replace function salon_private.validate_calendar_block_against_appointments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status <> 'active' then
    return new;
  end if;

  if exists (
    select 1
    from public.salon_appointments a
    where a.organization_id = new.organization_id
      and a.unit_id = new.unit_id
      and a.status in ('scheduled','confirmed','checked_in','in_service')
      and a.slot_range && tstzrange(new.starts_at, new.ends_at, '[)')
      and (
        (new.professional_id is null and new.resource_id is null)
        or new.professional_id = a.professional_id
      )
  ) then
    raise exception 'calendar block conflicts with appointment' using errcode = '23514';
  end if;

  if new.resource_id is not null and exists (
    select 1
    from public.salon_appointment_resources ar
    where ar.organization_id = new.organization_id
      and ar.resource_id = new.resource_id
      and ar.appointment_status in ('scheduled','confirmed','checked_in','in_service')
      and ar.slot_range && tstzrange(new.starts_at, new.ends_at, '[)')
  ) then
    raise exception 'calendar block conflicts with resource reservation' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger salon_clients_touch_updated_at
before update on public.salon_clients
for each row execute function salon_private.touch_updated_at();

create trigger salon_appointments_prepare
before insert or update on public.salon_appointments
for each row execute function salon_private.prepare_appointment();

create trigger salon_appointments_touch_updated_at
before update on public.salon_appointments
for each row execute function salon_private.touch_updated_at();

create trigger salon_appointments_sync_resources
after update on public.salon_appointments
for each row execute function salon_private.sync_appointment_resources();

create trigger salon_appointment_resources_prepare
before insert or update on public.salon_appointment_resources
for each row execute function salon_private.prepare_appointment_resource();

create trigger salon_calendar_blocks_validate_appointments
before insert or update on public.salon_calendar_blocks
for each row execute function salon_private.validate_calendar_block_against_appointments();

alter table public.salon_clients enable row level security;
alter table public.salon_appointments enable row level security;
alter table public.salon_appointment_resources enable row level security;

create policy "salon members read clients"
on public.salon_clients for select to authenticated
using (salon_private.is_active_member(organization_id));
create policy "salon reception creates clients"
on public.salon_clients for insert to authenticated
with check (
  salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist'])
  and (created_by is null or created_by = (select auth.uid()))
);
create policy "salon reception updates clients"
on public.salon_clients for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']));

create policy "salon members read appointments"
on public.salon_appointments for select to authenticated
using (salon_private.is_active_member(organization_id));
create policy "salon reception creates appointments"
on public.salon_appointments for insert to authenticated
with check (
  salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist'])
  and (created_by is null or created_by = (select auth.uid()))
);
create policy "salon reception updates appointments"
on public.salon_appointments for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']));

create policy "salon members read appointment resources"
on public.salon_appointment_resources for select to authenticated
using (salon_private.is_active_member(organization_id));
create policy "salon reception creates appointment resources"
on public.salon_appointment_resources for insert to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']));
create policy "salon reception updates appointment resources"
on public.salon_appointment_resources for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']));
create policy "salon reception removes appointment resources"
on public.salon_appointment_resources for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']));

grant select, insert, update on public.salon_clients to authenticated;
grant select, insert, update on public.salon_appointments to authenticated;
grant select, insert, update, delete on public.salon_appointment_resources to authenticated;
