create table public.salon_waitlist (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  unit_id uuid not null,
  client_id uuid not null,
  service_id uuid not null,
  professional_id uuid,
  window_starts_at timestamptz not null,
  window_ends_at timestamptz not null,
  status text not null default 'waiting' check (status in ('waiting','offered','booked','cancelled','expired')),
  matched_appointment_id uuid,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  constraint salon_waitlist_window_check check (window_starts_at < window_ends_at),
  constraint salon_waitlist_unit_same_org_fkey
    foreign key (organization_id, unit_id)
    references public.salon_units(organization_id, id),
  constraint salon_waitlist_client_same_org_fkey
    foreign key (organization_id, client_id)
    references public.salon_clients(organization_id, id),
  constraint salon_waitlist_service_same_org_fkey
    foreign key (organization_id, service_id)
    references public.salon_services(organization_id, id),
  constraint salon_waitlist_professional_same_org_fkey
    foreign key (organization_id, professional_id)
    references public.salon_professionals(organization_id, id),
  constraint salon_waitlist_appointment_same_org_fkey
    foreign key (organization_id, matched_appointment_id)
    references public.salon_appointments(organization_id, id)
);

create index salon_waitlist_org_status_window_idx
  on public.salon_waitlist (organization_id, status, window_starts_at, window_ends_at);
create index salon_waitlist_org_unit_fk_idx on public.salon_waitlist (organization_id, unit_id);
create index salon_waitlist_org_client_fk_idx on public.salon_waitlist (organization_id, client_id);
create index salon_waitlist_org_service_fk_idx on public.salon_waitlist (organization_id, service_id);
create index salon_waitlist_org_professional_fk_idx
  on public.salon_waitlist (organization_id, professional_id) where professional_id is not null;
create index salon_waitlist_org_appointment_fk_idx
  on public.salon_waitlist (organization_id, matched_appointment_id) where matched_appointment_id is not null;
create index salon_waitlist_created_by_idx
  on public.salon_waitlist (created_by) where created_by is not null;

create or replace function salon_private.validate_waitlist_entry()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_unit_status text;
  v_client_status text;
  v_service_status text;
  v_professional_status text;
  v_appt record;
begin
  select status into v_unit_status
  from public.salon_units
  where organization_id = new.organization_id and id = new.unit_id;
  if not found or v_unit_status <> 'active' then
    raise exception 'waitlist requires active unit' using errcode = '23514';
  end if;

  select status into v_client_status
  from public.salon_clients
  where organization_id = new.organization_id and id = new.client_id;
  if not found or v_client_status <> 'active' then
    raise exception 'waitlist requires active client' using errcode = '23514';
  end if;

  select status into v_service_status
  from public.salon_services
  where organization_id = new.organization_id and id = new.service_id;
  if not found or v_service_status <> 'active' then
    raise exception 'waitlist requires active service' using errcode = '23514';
  end if;

  if new.professional_id is not null then
    select status into v_professional_status
    from public.salon_professionals
    where organization_id = new.organization_id and id = new.professional_id;
    if not found or v_professional_status <> 'active' then
      raise exception 'waitlist professional must be active' using errcode = '23514';
    end if;

    if not exists (
      select 1 from public.salon_professional_services
      where organization_id = new.organization_id
        and professional_id = new.professional_id
        and service_id = new.service_id
    ) then
      raise exception 'waitlist professional is not assigned to service' using errcode = '23514';
    end if;
  end if;

  if new.status = 'booked' and new.matched_appointment_id is null then
    raise exception 'booked waitlist entry requires appointment' using errcode = '23514';
  end if;

  if new.matched_appointment_id is not null then
    select a.unit_id, a.client_id, a.service_id, a.professional_id, a.starts_at, a.status
      into v_appt
    from public.salon_appointments a
    where a.organization_id = new.organization_id and a.id = new.matched_appointment_id;
    if not found then
      raise exception 'matched appointment does not belong to organization' using errcode = '23514';
    end if;

    if new.status <> 'booked' then
      raise exception 'matched appointment requires booked waitlist status' using errcode = '23514';
    end if;
    if v_appt.unit_id <> new.unit_id or v_appt.client_id <> new.client_id or v_appt.service_id <> new.service_id then
      raise exception 'matched appointment does not match waitlist request' using errcode = '23514';
    end if;
    if new.professional_id is not null and v_appt.professional_id <> new.professional_id then
      raise exception 'matched appointment uses another professional' using errcode = '23514';
    end if;
    if v_appt.starts_at < new.window_starts_at or v_appt.starts_at >= new.window_ends_at then
      raise exception 'matched appointment is outside waitlist window' using errcode = '23514';
    end if;
    if v_appt.status in ('cancelled','no_show') then
      raise exception 'matched appointment is not active' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create trigger salon_waitlist_validate
before insert or update on public.salon_waitlist
for each row execute function salon_private.validate_waitlist_entry();

create trigger salon_waitlist_touch_updated_at
before update on public.salon_waitlist
for each row execute function salon_private.touch_updated_at();

alter table public.salon_waitlist enable row level security;

create policy "salon members read waitlist"
on public.salon_waitlist for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon reception creates waitlist"
on public.salon_waitlist for insert to authenticated
with check (
  salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist'])
  and (created_by is null or created_by = (select auth.uid()))
);

create policy "salon reception updates waitlist"
on public.salon_waitlist for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist']));

grant select, insert, update on public.salon_waitlist to authenticated;
