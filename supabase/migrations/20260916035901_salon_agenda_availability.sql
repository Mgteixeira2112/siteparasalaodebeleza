create extension if not exists btree_gist with schema extensions;

alter table public.salon_resources
  add constraint salon_resources_org_id_unique unique (organization_id, id);

create table public.salon_professional_availability (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  professional_id uuid not null,
  unit_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),
  starts_at time without time zone not null,
  ends_at time without time zone not null,
  slot_range int8range generated always as (
    int8range(
      extract(epoch from starts_at)::bigint,
      extract(epoch from ends_at)::bigint,
      '[)'
    )
  ) stored,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint salon_professional_availability_time_check check (starts_at < ends_at),
  constraint salon_professional_availability_professional_same_org_fkey
    foreign key (organization_id, professional_id)
    references public.salon_professionals(organization_id, id) on delete cascade,
  constraint salon_professional_availability_unit_same_org_fkey
    foreign key (organization_id, unit_id)
    references public.salon_units(organization_id, id) on delete cascade,
  constraint salon_professional_availability_no_overlap
    exclude using gist (
      organization_id with =,
      professional_id with =,
      unit_id with =,
      weekday with =,
      slot_range with &&
    ) where (status = 'active')
);

create table public.salon_calendar_blocks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  unit_id uuid not null,
  professional_id uuid,
  resource_id uuid,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  source text not null default 'manual',
  status text not null default 'active' check (status in ('active','cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint salon_calendar_blocks_time_check check (starts_at < ends_at),
  constraint salon_calendar_blocks_unit_same_org_fkey
    foreign key (organization_id, unit_id)
    references public.salon_units(organization_id, id) on delete cascade,
  constraint salon_calendar_blocks_professional_same_org_fkey
    foreign key (organization_id, professional_id)
    references public.salon_professionals(organization_id, id) on delete cascade,
  constraint salon_calendar_blocks_resource_same_org_fkey
    foreign key (organization_id, resource_id)
    references public.salon_resources(organization_id, id) on delete cascade
);

create index salon_professional_availability_org_weekday_idx
  on public.salon_professional_availability (organization_id, weekday, status);
create index salon_professional_availability_professional_idx
  on public.salon_professional_availability (professional_id);
create index salon_professional_availability_unit_idx
  on public.salon_professional_availability (unit_id);

create index salon_calendar_blocks_org_time_idx
  on public.salon_calendar_blocks (organization_id, starts_at, ends_at)
  where status = 'active';
create index salon_calendar_blocks_unit_idx
  on public.salon_calendar_blocks (unit_id, starts_at)
  where status = 'active';
create index salon_calendar_blocks_professional_idx
  on public.salon_calendar_blocks (professional_id, starts_at)
  where professional_id is not null and status = 'active';
create index salon_calendar_blocks_resource_idx
  on public.salon_calendar_blocks (resource_id, starts_at)
  where resource_id is not null and status = 'active';
create index salon_calendar_blocks_created_by_idx
  on public.salon_calendar_blocks (created_by)
  where created_by is not null;

create trigger salon_professional_availability_touch_updated_at
before update on public.salon_professional_availability
for each row execute function salon_private.touch_updated_at();

create trigger salon_calendar_blocks_touch_updated_at
before update on public.salon_calendar_blocks
for each row execute function salon_private.touch_updated_at();

alter table public.salon_professional_availability enable row level security;
alter table public.salon_calendar_blocks enable row level security;

create policy "salon members read professional availability"
on public.salon_professional_availability
for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create professional availability"
on public.salon_professional_availability
for insert to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']));

create policy "salon managers update professional availability"
on public.salon_professional_availability
for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']));

create policy "salon managers delete professional availability"
on public.salon_professional_availability
for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']));

create policy "salon members read calendar blocks"
on public.salon_calendar_blocks
for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create calendar blocks"
on public.salon_calendar_blocks
for insert to authenticated
with check (
  salon_private.has_org_role(organization_id, array['owner','admin','manager'])
  and (created_by is null or created_by = (select auth.uid()))
);

create policy "salon managers update calendar blocks"
on public.salon_calendar_blocks
for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']));

create policy "salon managers delete calendar blocks"
on public.salon_calendar_blocks
for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']));

grant select, insert, update, delete on public.salon_professional_availability to authenticated;
grant select, insert, update, delete on public.salon_calendar_blocks to authenticated;
