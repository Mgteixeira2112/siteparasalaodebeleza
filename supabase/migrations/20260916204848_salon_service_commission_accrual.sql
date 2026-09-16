create table public.salon_commission_rules (
  organization_id uuid not null references public.salon_organizations(id),
  professional_id uuid not null,
  service_id uuid not null,
  commission_bps integer not null check (commission_bps between 0 and 10000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint salon_commission_rules_pkey primary key (organization_id, professional_id, service_id),
  constraint salon_commission_rules_assignment_fkey foreign key (organization_id, professional_id, service_id)
    references public.salon_professional_services(organization_id, professional_id, service_id) on delete cascade
);
create index salon_commission_rules_service_idx on public.salon_commission_rules (organization_id, service_id);
create trigger salon_commission_rules_touch before update on public.salon_commission_rules
  for each row execute function salon_private.touch_updated_at();
alter table public.salon_commission_rules enable row level security;
create policy "salon managers and own professional read commission rules" on public.salon_commission_rules
  for select to authenticated using (
    salon_private.has_org_role(organization_id, array['owner','admin','manager'])
    or exists (
      select 1 from public.salon_professionals p
      join public.salon_members m on m.organization_id = p.organization_id and m.id = p.member_id
      where p.organization_id = salon_commission_rules.organization_id
        and p.id = salon_commission_rules.professional_id
        and m.user_id = (select auth.uid()) and m.status = 'active'
    )
  );
create policy "salon managers insert commission rules" on public.salon_commission_rules
  for insert to authenticated with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']));
create policy "salon managers update commission rules" on public.salon_commission_rules
  for update to authenticated using (salon_private.has_org_role(organization_id, array['owner','admin','manager']))
  with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']));
create policy "salon managers delete commission rules" on public.salon_commission_rules
  for delete to authenticated using (salon_private.has_org_role(organization_id, array['owner','admin','manager']));
revoke all on public.salon_commission_rules from public, anon, authenticated;
grant select, delete on public.salon_commission_rules to authenticated;
grant insert (organization_id, professional_id, service_id, commission_bps) on public.salon_commission_rules to authenticated;
grant update (commission_bps) on public.salon_commission_rules to authenticated;

create table public.salon_commission_accruals (
  organization_id uuid not null references public.salon_organizations(id),
  appointment_id uuid not null,
  unit_id uuid not null,
  professional_id uuid not null,
  service_id uuid not null,
  service_price_cents integer not null check (service_price_cents >= 0),
  commission_bps integer not null check (commission_bps between 0 and 10000),
  rule_configured boolean not null,
  commission_cents bigint not null check (commission_cents >= 0),
  completed_at timestamptz not null default clock_timestamp(),
  constraint salon_commission_accruals_pkey primary key (organization_id, appointment_id),
  constraint salon_commission_accruals_appointment_fkey foreign key (organization_id,appointment_id)
    references public.salon_appointments(organization_id,id),
  constraint salon_commission_accruals_unit_fkey foreign key (organization_id,unit_id)
    references public.salon_units(organization_id,id),
  constraint salon_commission_accruals_professional_fkey foreign key (organization_id,professional_id)
    references public.salon_professionals(organization_id,id),
  constraint salon_commission_accruals_service_fkey foreign key (organization_id,service_id)
    references public.salon_services(organization_id,id),
  constraint salon_commission_accruals_math_check check (
    commission_cents = (service_price_cents::bigint * commission_bps + 5000) / 10000
  )
);
create index salon_commission_accruals_professional_idx on public.salon_commission_accruals (organization_id,professional_id,completed_at);
create index salon_commission_accruals_unit_idx on public.salon_commission_accruals (organization_id,unit_id,completed_at);
create index salon_commission_accruals_service_idx on public.salon_commission_accruals (organization_id,service_id);
alter table public.salon_commission_accruals enable row level security;
create policy "salon managers and own professional read commission accruals" on public.salon_commission_accruals
  for select to authenticated using (
    salon_private.has_org_role(organization_id, array['owner','admin','manager'])
    or exists (
      select 1 from public.salon_professionals p
      join public.salon_members m on m.organization_id = p.organization_id and m.id = p.member_id
      where p.organization_id = salon_commission_accruals.organization_id
        and p.id = salon_commission_accruals.professional_id
        and m.user_id = (select auth.uid()) and m.status = 'active'
    )
  );
revoke all on public.salon_commission_accruals from public, anon, authenticated;
grant select on public.salon_commission_accruals to authenticated;

create function salon_private.accrue_service_commission_on_completion()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_rate integer; v_configured boolean;
begin
  if new.status = 'completed' and old.status is distinct from new.status then
    select r.commission_bps into v_rate
    from public.salon_commission_rules r
    where r.organization_id = new.organization_id
      and r.professional_id = new.professional_id and r.service_id = new.service_id;
    v_configured := found;
    v_rate := coalesce(v_rate,0);
    insert into public.salon_commission_accruals (
      organization_id,appointment_id,unit_id,professional_id,service_id,
      service_price_cents,commission_bps,rule_configured,commission_cents
    ) values (
      new.organization_id,new.id,new.unit_id,new.professional_id,new.service_id,
      new.service_price_cents,v_rate,v_configured,
      (new.service_price_cents::bigint*v_rate + 5000)/10000
    ) on conflict (organization_id,appointment_id) do nothing;
  end if;
  return new;
end $fn$;
revoke all on function salon_private.accrue_service_commission_on_completion() from public,anon,authenticated;
create trigger salon_appointments_accrue_service_commission
  after update of status on public.salon_appointments for each row
  execute function salon_private.accrue_service_commission_on_completion();

create function salon_private.lock_completed_appointment_professional()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if old.status = 'completed' and new.professional_id is distinct from old.professional_id then
    raise exception 'completed appointment professional is immutable for commission audit' using errcode = '23514';
  end if;
  return new;
end $fn$;
revoke all on function salon_private.lock_completed_appointment_professional() from public,anon,authenticated;
create trigger salon_appointments_lock_completed_professional
  before update of professional_id on public.salon_appointments for each row
  execute function salon_private.lock_completed_appointment_professional();