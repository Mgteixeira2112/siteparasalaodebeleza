create schema if not exists salon_private;
revoke all on schema salon_private from public, anon, authenticated;

create table public.salon_organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  status text not null default 'active' check (status in ('active','inactive')),
  timezone text not null default 'America/Sao_Paulo',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.salon_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','admin','manager','receptionist','professional','cashier')),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table public.salon_units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  code text,
  status text not null default 'active' check (status in ('active','inactive')),
  timezone text not null default 'America/Sao_Paulo',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code)
);

create index salon_members_user_id_idx on public.salon_members(user_id);
create index salon_members_org_status_idx on public.salon_members(organization_id, status);
create index salon_units_org_status_idx on public.salon_units(organization_id, status);

create or replace function salon_private.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function salon_private.bootstrap_owner_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.salon_members (organization_id, user_id, role, status)
  values (new.id, new.created_by, 'owner', 'active')
  on conflict (organization_id, user_id) do nothing;
  return new;
end;
$$;

revoke all on function salon_private.touch_updated_at() from public, anon, authenticated;
revoke all on function salon_private.bootstrap_owner_membership() from public, anon, authenticated;

create trigger salon_organizations_touch_updated_at
before update on public.salon_organizations
for each row execute function salon_private.touch_updated_at();

create trigger salon_units_touch_updated_at
before update on public.salon_units
for each row execute function salon_private.touch_updated_at();

create trigger salon_organizations_bootstrap_owner
before insert on public.salon_organizations
for each row execute function salon_private.bootstrap_owner_membership();

alter table public.salon_organizations enable row level security;
alter table public.salon_members enable row level security;
alter table public.salon_units enable row level security;

create policy "salon members read own membership"
on public.salon_members
for select
to authenticated
using ((select auth.uid()) is not null and user_id = (select auth.uid()));

create policy "salon members read organizations"
on public.salon_organizations
for select
to authenticated
using (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_organizations.id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
  )
);

create policy "salon users create organization"
on public.salon_organizations
for insert
to authenticated
with check ((select auth.uid()) is not null and created_by = (select auth.uid()));

create policy "salon admins update organization"
on public.salon_organizations
for update
to authenticated
using (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_organizations.id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_organizations.id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role in ('owner','admin')
  )
);

create policy "salon members read units"
on public.salon_units
for select
to authenticated
using (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_units.organization_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
  )
);

create policy "salon managers create units"
on public.salon_units
for insert
to authenticated
with check (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_units.organization_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role in ('owner','admin','manager')
  )
);

create policy "salon managers update units"
on public.salon_units
for update
to authenticated
using (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_units.organization_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role in ('owner','admin','manager')
  )
)
with check (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_units.organization_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role in ('owner','admin','manager')
  )
);

create policy "salon admins delete units"
on public.salon_units
for delete
to authenticated
using (
  exists (
    select 1
    from public.salon_members m
    where m.organization_id = salon_units.organization_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.role in ('owner','admin')
  )
);

grant select, insert on public.salon_organizations to authenticated;
grant update (name, status, timezone) on public.salon_organizations to authenticated;
grant select on public.salon_members to authenticated;
grant select, insert, delete on public.salon_units to authenticated;
grant update (name, code, status, timezone) on public.salon_units to authenticated;