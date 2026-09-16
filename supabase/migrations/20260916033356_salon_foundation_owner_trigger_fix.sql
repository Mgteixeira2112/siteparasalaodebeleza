drop trigger if exists salon_organizations_bootstrap_owner on public.salon_organizations;

create trigger salon_organizations_bootstrap_owner
after insert on public.salon_organizations
for each row execute function salon_private.bootstrap_owner_membership();