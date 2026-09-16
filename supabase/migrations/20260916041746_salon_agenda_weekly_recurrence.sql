create table public.salon_recurrence_series (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  unit_id uuid not null,
  client_id uuid not null,
  service_id uuid not null,
  professional_id uuid not null,
  first_starts_at timestamptz not null,
  interval_weeks integer not null default 1 check (interval_weeks between 1 and 52),
  occurrence_count integer not null check (occurrence_count between 2 and 52),
  status text not null default 'active' check (status in ('active','cancelled')),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  constraint salon_recurrence_series_unit_same_org_fkey
    foreign key (organization_id, unit_id)
    references public.salon_units(organization_id, id),
  constraint salon_recurrence_series_client_same_org_fkey
    foreign key (organization_id, client_id)
    references public.salon_clients(organization_id, id),
  constraint salon_recurrence_series_service_same_org_fkey
    foreign key (organization_id, service_id)
    references public.salon_services(organization_id, id),
  constraint salon_recurrence_series_professional_same_org_fkey
    foreign key (organization_id, professional_id)
    references public.salon_professionals(organization_id, id)
);

alter table public.salon_appointments
  add column recurrence_series_id uuid,
  add column recurrence_sequence integer;

alter table public.salon_appointments
  add constraint salon_appointments_recurrence_series_same_org_fkey
  foreign key (organization_id, recurrence_series_id)
  references public.salon_recurrence_series(organization_id, id);

alter table public.salon_appointments
  add constraint salon_appointments_recurrence_pair_check
  check (
    (recurrence_series_id is null and recurrence_sequence is null)
    or (recurrence_series_id is not null and recurrence_sequence is not null and recurrence_sequence > 0)
  );

create unique index salon_appointments_recurrence_sequence_unique
  on public.salon_appointments (organization_id, recurrence_series_id, recurrence_sequence)
  where recurrence_series_id is not null;

create index salon_recurrence_series_org_status_idx
  on public.salon_recurrence_series (organization_id, status, first_starts_at);
create index salon_recurrence_series_org_unit_fk_idx
  on public.salon_recurrence_series (organization_id, unit_id);
create index salon_recurrence_series_org_client_fk_idx
  on public.salon_recurrence_series (organization_id, client_id);
create index salon_recurrence_series_org_service_fk_idx
  on public.salon_recurrence_series (organization_id, service_id);
create index salon_recurrence_series_org_professional_fk_idx
  on public.salon_recurrence_series (organization_id, professional_id);
create index salon_recurrence_series_created_by_idx
  on public.salon_recurrence_series (created_by) where created_by is not null;
create index salon_appointments_org_recurrence_fk_idx
  on public.salon_appointments (organization_id, recurrence_series_id)
  where recurrence_series_id is not null;

create trigger salon_recurrence_series_touch_updated_at
before update on public.salon_recurrence_series
for each row execute function salon_private.touch_updated_at();

alter table public.salon_recurrence_series enable row level security;

create policy "salon members read recurrence series"
on public.salon_recurrence_series for select to authenticated
using (salon_private.is_active_member(organization_id));

grant select on public.salon_recurrence_series to authenticated;

create or replace function public.salon_create_weekly_recurrence(
  p_organization_id uuid,
  p_unit_id uuid,
  p_client_id uuid,
  p_service_id uuid,
  p_professional_id uuid,
  p_first_starts_at timestamptz,
  p_occurrence_count integer,
  p_interval_weeks integer default 1
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_series_id uuid := gen_random_uuid();
  v_timezone text;
  v_local_first timestamp without time zone;
  v_occurrence_starts_at timestamptz;
  v_sequence integer;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not salon_private.has_org_role(p_organization_id, array['owner','admin','manager','receptionist']) then
    raise exception 'insufficient salon role' using errcode = '42501';
  end if;
  if p_occurrence_count < 2 or p_occurrence_count > 52 then
    raise exception 'occurrence count must be between 2 and 52' using errcode = '22023';
  end if;
  if p_interval_weeks < 1 or p_interval_weeks > 52 then
    raise exception 'interval weeks must be between 1 and 52' using errcode = '22023';
  end if;

  select u.timezone into v_timezone
  from public.salon_units u
  where u.organization_id = p_organization_id and u.id = p_unit_id;
  if not found then
    raise exception 'unit does not belong to organization' using errcode = '23514';
  end if;

  v_local_first := p_first_starts_at at time zone v_timezone;

  insert into public.salon_recurrence_series(
    id, organization_id, unit_id, client_id, service_id, professional_id,
    first_starts_at, interval_weeks, occurrence_count, created_by
  ) values (
    v_series_id, p_organization_id, p_unit_id, p_client_id, p_service_id, p_professional_id,
    p_first_starts_at, p_interval_weeks, p_occurrence_count, v_user_id
  );

  for v_sequence in 1..p_occurrence_count loop
    v_occurrence_starts_at :=
      (v_local_first + ((v_sequence - 1) * p_interval_weeks) * interval '1 week') at time zone v_timezone;

    insert into public.salon_appointments(
      organization_id, unit_id, client_id, service_id, professional_id,
      starts_at, status, source, created_by, recurrence_series_id, recurrence_sequence
    ) values (
      p_organization_id, p_unit_id, p_client_id, p_service_id, p_professional_id,
      v_occurrence_starts_at, 'scheduled', 'recurrence', v_user_id, v_series_id, v_sequence
    );
  end loop;

  return v_series_id;
end;
$$;

revoke all on function public.salon_create_weekly_recurrence(uuid,uuid,uuid,uuid,uuid,timestamptz,integer,integer) from public;
revoke all on function public.salon_create_weekly_recurrence(uuid,uuid,uuid,uuid,uuid,timestamptz,integer,integer) from anon;
grant execute on function public.salon_create_weekly_recurrence(uuid,uuid,uuid,uuid,uuid,timestamptz,integer,integer) to authenticated;

create or replace function public.salon_cancel_recurrence(
  p_organization_id uuid,
  p_series_id uuid,
  p_from timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_cancelled integer;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not salon_private.has_org_role(p_organization_id, array['owner','admin','manager','receptionist']) then
    raise exception 'insufficient salon role' using errcode = '42501';
  end if;

  update public.salon_recurrence_series
     set status = 'cancelled'
   where organization_id = p_organization_id and id = p_series_id;
  if not found then
    raise exception 'recurrence series not found' using errcode = 'P0002';
  end if;

  update public.salon_appointments
     set status = 'cancelled'
   where organization_id = p_organization_id
     and recurrence_series_id = p_series_id
     and starts_at >= p_from
     and status in ('scheduled','confirmed','checked_in');

  get diagnostics v_cancelled = row_count;
  return v_cancelled;
end;
$$;

revoke all on function public.salon_cancel_recurrence(uuid,uuid,timestamptz) from public;
revoke all on function public.salon_cancel_recurrence(uuid,uuid,timestamptz) from anon;
grant execute on function public.salon_cancel_recurrence(uuid,uuid,timestamptz) to authenticated;
