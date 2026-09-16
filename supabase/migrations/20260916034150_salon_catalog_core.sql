alter table public.salon_members
  add constraint salon_members_organization_id_id_key unique (organization_id, id);

alter table public.salon_units
  add constraint salon_units_organization_id_id_key unique (organization_id, id);

create table public.salon_professionals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  member_id uuid,
  display_name text not null check (btrim(display_name) <> ''),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, member_id),
  constraint salon_professionals_member_same_org_fkey
    foreign key (organization_id, member_id)
    references public.salon_members(organization_id, id)
    on delete set null
);

create table public.salon_services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  duration_minutes integer not null check (duration_minutes > 0),
  base_price_cents bigint not null default 0 check (base_price_cents >= 0),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);

create table public.salon_resources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  unit_id uuid,
  name text not null check (btrim(name) <> ''),
  resource_type text not null check (btrim(resource_type) <> ''),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint salon_resources_unit_same_org_fkey
    foreign key (organization_id, unit_id)
    references public.salon_units(organization_id, id)
    on delete set null
);

create table public.salon_professional_services (
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  professional_id uuid not null,
  service_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (organization_id, professional_id, service_id),
  constraint salon_professional_services_professional_same_org_fkey
    foreign key (organization_id, professional_id)
    references public.salon_professionals(organization_id, id)
    on delete cascade,
  constraint salon_professional_services_service_same_org_fkey
    foreign key (organization_id, service_id)
    references public.salon_services(organization_id, id)
    on delete cascade
);

create index salon_professionals_org_status_idx
  on public.salon_professionals(organization_id, status);
create index salon_professionals_org_member_idx
  on public.salon_professionals(organization_id, member_id);
create index salon_services_org_status_idx
  on public.salon_services(organization_id, status);
create index salon_resources_org_status_idx
  on public.salon_resources(organization_id, status);
create index salon_resources_org_unit_idx
  on public.salon_resources(organization_id, unit_id);
create index salon_professional_services_service_idx
  on public.salon_professional_services(organization_id, service_id);

create trigger salon_professionals_touch_updated_at
before update on public.salon_professionals
for each row execute function salon_private.touch_updated_at();

create trigger salon_services_touch_updated_at
before update on public.salon_services
for each row execute function salon_private.touch_updated_at();

create trigger salon_resources_touch_updated_at
before update on public.salon_resources
for each row execute function salon_private.touch_updated_at();

alter table public.salon_professionals enable row level security;
alter table public.salon_services enable row level security;
alter table public.salon_resources enable row level security;
alter table public.salon_professional_services enable row level security;

create policy "salon members read professionals"
on public.salon_professionals
for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create professionals"
on public.salon_professionals
for insert to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon managers update professionals"
on public.salon_professionals
for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon admins delete professionals"
on public.salon_professionals
for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin']::text[]));

create policy "salon members read services"
on public.salon_services
for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create services"
on public.salon_services
for insert to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon managers update services"
on public.salon_services
for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon admins delete services"
on public.salon_services
for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin']::text[]));

create policy "salon members read resources"
on public.salon_resources
for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create resources"
on public.salon_resources
for insert to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon managers update resources"
on public.salon_resources
for update to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon admins delete resources"
on public.salon_resources
for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin']::text[]));

create policy "salon members read professional services"
on public.salon_professional_services
for select to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create professional services"
on public.salon_professional_services
for insert to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon managers delete professional services"
on public.salon_professional_services
for delete to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

grant select, insert, delete on public.salon_professionals to authenticated;
grant update (member_id, display_name, status) on public.salon_professionals to authenticated;

grant select, insert, delete on public.salon_services to authenticated;
grant update (name, duration_minutes, base_price_cents, status) on public.salon_services to authenticated;

grant select, insert, delete on public.salon_resources to authenticated;
grant update (unit_id, name, resource_type, status) on public.salon_resources to authenticated;

grant select, insert, delete on public.salon_professional_services to authenticated;