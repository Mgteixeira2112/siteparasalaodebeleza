alter table public.salon_appointments
  add column service_price_cents integer;

update public.salon_appointments a
   set service_price_cents = s.base_price_cents
  from public.salon_services s
 where s.organization_id = a.organization_id
   and s.id = a.service_id;

alter table public.salon_appointments
  alter column service_price_cents set not null,
  add constraint salon_appointments_service_price_cents_check check (service_price_cents >= 0);

create or replace function salon_private.capture_appointment_service_price()
returns trigger
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_price integer;
begin
  if tg_op = 'INSERT' or new.service_id is distinct from old.service_id then
    select s.base_price_cents
      into v_price
      from public.salon_services s
     where s.organization_id = new.organization_id
       and s.id = new.service_id;

    if not found then
      raise exception 'service does not belong to organization' using errcode = '23514';
    end if;

    new.service_price_cents := v_price;
  elsif new.service_price_cents is distinct from old.service_price_cents then
    raise exception 'appointment service price snapshot is immutable' using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists salon_appointments_capture_service_price on public.salon_appointments;
create trigger salon_appointments_capture_service_price
before insert or update of service_id, service_price_cents on public.salon_appointments
for each row
execute function salon_private.capture_appointment_service_price();
