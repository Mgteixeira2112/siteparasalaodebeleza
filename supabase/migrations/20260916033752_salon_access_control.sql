create or replace function salon_private.is_active_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and exists (
      select 1
      from public.salon_members m
      where m.organization_id = target_organization_id
        and m.user_id = (select auth.uid())
        and m.status = 'active'
    );
$$;

create or replace function salon_private.has_org_role(target_organization_id uuid, allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and exists (
      select 1
      from public.salon_members m
      where m.organization_id = target_organization_id
        and m.user_id = (select auth.uid())
        and m.status = 'active'
        and m.role = any(allowed_roles)
    );
$$;

revoke all on function salon_private.is_active_member(uuid) from public, anon, authenticated;
revoke all on function salon_private.has_org_role(uuid, text[]) from public, anon, authenticated;
grant usage on schema salon_private to authenticated;
grant execute on function salon_private.is_active_member(uuid) to authenticated;
grant execute on function salon_private.has_org_role(uuid, text[]) to authenticated;

drop policy if exists "salon members read own membership" on public.salon_members;
drop policy if exists "salon members read organizations" on public.salon_organizations;
drop policy if exists "salon admins update organization" on public.salon_organizations;
drop policy if exists "salon members read units" on public.salon_units;
drop policy if exists "salon managers create units" on public.salon_units;
drop policy if exists "salon managers update units" on public.salon_units;
drop policy if exists "salon admins delete units" on public.salon_units;

create policy "salon members read memberships"
on public.salon_members
for select
to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon owners add members"
on public.salon_members
for insert
to authenticated
with check (salon_private.has_org_role(organization_id, array['owner']::text[]));

create policy "salon owners update other members"
on public.salon_members
for update
to authenticated
using (
  salon_private.has_org_role(organization_id, array['owner']::text[])
  and user_id <> (select auth.uid())
)
with check (
  salon_private.has_org_role(organization_id, array['owner']::text[])
  and user_id <> (select auth.uid())
);

create policy "salon owners delete other members"
on public.salon_members
for delete
to authenticated
using (
  salon_private.has_org_role(organization_id, array['owner']::text[])
  and user_id <> (select auth.uid())
);

create policy "salon members read organizations"
on public.salon_organizations
for select
to authenticated
using (salon_private.is_active_member(id));

create policy "salon admins update organization"
on public.salon_organizations
for update
to authenticated
using (salon_private.has_org_role(id, array['owner','admin']::text[]))
with check (salon_private.has_org_role(id, array['owner','admin']::text[]));

create policy "salon members read units"
on public.salon_units
for select
to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon managers create units"
on public.salon_units
for insert
to authenticated
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon managers update units"
on public.salon_units
for update
to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon admins delete units"
on public.salon_units
for delete
to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin']::text[]));

grant insert, delete on public.salon_members to authenticated;
grant update (role, status) on public.salon_members to authenticated;