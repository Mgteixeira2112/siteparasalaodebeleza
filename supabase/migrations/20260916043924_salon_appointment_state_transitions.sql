create or replace function salon_private.valid_appointment_transition(p_from text, p_to text)
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select
    p_from = p_to
    or (p_from = 'scheduled' and p_to in ('confirmed','checked_in','cancelled','no_show'))
    or (p_from = 'confirmed' and p_to in ('checked_in','cancelled','no_show'))
    or (p_from = 'checked_in' and p_to in ('in_service','cancelled'))
    or (p_from = 'in_service' and p_to in ('completed','cancelled'));
$$;

create or replace function salon_private.enforce_appointment_status_transition()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status is distinct from old.status
     and not salon_private.valid_appointment_transition(old.status, new.status) then
    raise exception 'invalid appointment status transition: % -> %', old.status, new.status
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists salon_appointments_enforce_status_transition on public.salon_appointments;
create trigger salon_appointments_enforce_status_transition
before update of status on public.salon_appointments
for each row
execute function salon_private.enforce_appointment_status_transition();

create or replace function public.salon_transition_appointment(
  p_organization_id uuid,
  p_appointment_id uuid,
  p_to_status text
)
returns public.salon_appointments
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_appointment public.salon_appointments;
begin
  if p_to_status not in ('scheduled','confirmed','checked_in','in_service','completed','cancelled','no_show') then
    raise exception 'invalid appointment status: %', p_to_status using errcode = '23514';
  end if;

  update public.salon_appointments
     set status = p_to_status
   where organization_id = p_organization_id
     and id = p_appointment_id
  returning * into v_appointment;

  if not found then
    raise exception 'appointment not found or not authorized' using errcode = 'P0002';
  end if;

  return v_appointment;
end;
$$;

revoke execute on function public.salon_transition_appointment(uuid, uuid, text) from public, anon;
grant execute on function public.salon_transition_appointment(uuid, uuid, text) to authenticated;
