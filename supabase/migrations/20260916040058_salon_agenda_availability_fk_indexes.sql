create index salon_professional_availability_org_unit_fk_idx
  on public.salon_professional_availability (organization_id, unit_id);

create index salon_calendar_blocks_org_unit_fk_idx
  on public.salon_calendar_blocks (organization_id, unit_id);

create index salon_calendar_blocks_org_professional_fk_idx
  on public.salon_calendar_blocks (organization_id, professional_id)
  where professional_id is not null;

create index salon_calendar_blocks_org_resource_fk_idx
  on public.salon_calendar_blocks (organization_id, resource_id)
  where resource_id is not null;
