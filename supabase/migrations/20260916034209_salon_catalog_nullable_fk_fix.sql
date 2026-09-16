alter table public.salon_professionals
  drop constraint salon_professionals_member_same_org_fkey;

alter table public.salon_professionals
  add constraint salon_professionals_member_same_org_fkey
  foreign key (organization_id, member_id)
  references public.salon_members(organization_id, id)
  on delete set null (member_id);

alter table public.salon_resources
  drop constraint salon_resources_unit_same_org_fkey;

alter table public.salon_resources
  add constraint salon_resources_unit_same_org_fkey
  foreign key (organization_id, unit_id)
  references public.salon_units(organization_id, id)
  on delete set null (unit_id);