create schema if not exists salon_booking_private;
revoke all on schema salon_booking_private from public, anon, authenticated;

alter table public.salon_appointments
  add column online_request_id uuid;

create unique index salon_appointments_online_request_uidx
  on public.salon_appointments (online_request_id)
  where online_request_id is not null;

alter table public.salon_appointments
  add constraint salon_appointments_online_request_check
  check (
    (source = 'online' and online_request_id is not null)
    or (source <> 'online' and online_request_id is null)
  );

create or replace function salon_booking_private.catalog(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'organization', jsonb_build_object(
      'id', o.id,
      'name', o.name,
      'timezone', o.timezone
    ),
    'units', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', u.id,
          'name', u.name,
          'code', u.code,
          'timezone', u.timezone
        ) order by u.name, u.id
      )
      from public.salon_units u
      where u.organization_id = o.id
        and u.status = 'active'
    ), '[]'::jsonb),
    'services', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'name', s.name,
          'duration_minutes', s.duration_minutes,
          'base_price_cents', s.base_price_cents,
          'professionals', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', p.id,
                'display_name', p.display_name
              ) order by p.display_name, p.id
            )
            from public.salon_professional_services ps
            join public.salon_professionals p
              on p.organization_id = ps.organization_id
             and p.id = ps.professional_id
            where ps.organization_id = o.id
              and ps.service_id = s.id
              and p.status = 'active'
          ), '[]'::jsonb)
        ) order by s.name, s.id
      )
      from public.salon_services s
      where s.organization_id = o.id
        and s.status = 'active'
    ), '[]'::jsonb)
  )
  into v_result
  from public.salon_organizations o
  where o.id = p_organization_id
    and o.status = 'active';

  if v_result is null then
    raise exception 'salon is not available for public booking' using errcode = 'P0001';
  end if;

  return v_result;
end;
$$;

create or replace function salon_booking_private.available_slots(
  p_organization_id uuid,
  p_unit_id uuid,
  p_service_id uuid,
  p_date date,
  p_professional_id uuid default null
)
returns table (
  starts_at timestamptz,
  ends_at timestamptz,
  professional_id uuid,
  professional_name text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_duration integer;
  v_timezone text;
  v_local_today date;
begin
  select s.duration_minutes, u.timezone
    into v_duration, v_timezone
  from public.salon_services s
  join public.salon_units u
    on u.organization_id = s.organization_id
   and u.id = p_unit_id
  join public.salon_organizations o
    on o.id = s.organization_id
  where s.organization_id = p_organization_id
    and s.id = p_service_id
    and s.status = 'active'
    and u.status = 'active'
    and o.status = 'active';

  if not found then
    raise exception 'unit or service is not available for public booking' using errcode = 'P0001';
  end if;

  v_local_today := (pg_catalog.now() at time zone v_timezone)::date;
  if p_date < v_local_today or p_date > v_local_today + 180 then
    raise exception 'booking date must be between today and 180 days ahead' using errcode = '22007';
  end if;

  return query
  with candidate_slots as (
    select
      ((p_date + gs.local_start::time) at time zone v_timezone) as slot_start,
      (((p_date + gs.local_start::time) + (v_duration * interval '1 minute')) at time zone v_timezone) as slot_end,
      p.id as professional_id,
      p.display_name as professional_name
    from public.salon_professionals p
    join public.salon_professional_services ps
      on ps.organization_id = p.organization_id
     and ps.professional_id = p.id
     and ps.service_id = p_service_id
    join public.salon_professional_availability a
      on a.organization_id = p.organization_id
     and a.professional_id = p.id
     and a.unit_id = p_unit_id
     and a.weekday = extract(dow from p_date)::smallint
     and a.status = 'active'
    cross join lateral (
      select x as local_start
      from pg_catalog.generate_series(
        p_date::timestamp + a.starts_at,
        p_date::timestamp + a.ends_at - (v_duration * interval '1 minute'),
        v_duration * interval '1 minute'
      ) x
    ) gs
    where p.organization_id = p_organization_id
      and p.status = 'active'
      and (p_professional_id is null or p.id = p_professional_id)
  )
  select c.slot_start, c.slot_end, c.professional_id, c.professional_name
  from candidate_slots c
  where c.slot_start >= pg_catalog.now()
    and not exists (
      select 1
      from public.salon_calendar_blocks b
      where b.organization_id = p_organization_id
        and b.unit_id = p_unit_id
        and b.status = 'active'
        and tstzrange(b.starts_at, b.ends_at, '[)') && tstzrange(c.slot_start, c.slot_end, '[)')
        and (
          (b.professional_id is null and b.resource_id is null)
          or b.professional_id = c.professional_id
        )
    )
    and not exists (
      select 1
      from public.salon_appointments ap
      where ap.organization_id = p_organization_id
        and ap.professional_id = c.professional_id
        and ap.status in ('scheduled','confirmed','checked_in','in_service')
        and ap.slot_range && tstzrange(c.slot_start, c.slot_end, '[)')
    )
  order by c.slot_start, c.professional_name, c.professional_id;
end;
$$;

create or replace function salon_booking_private.book(
  p_request_id uuid,
  p_organization_id uuid,
  p_unit_id uuid,
  p_service_id uuid,
  p_starts_at timestamptz,
  p_client_name text,
  p_client_phone text default null,
  p_client_email text default null,
  p_professional_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.salon_appointments%rowtype;
  v_client_id uuid;
  v_prof record;
  v_appointment public.salon_appointments%rowtype;
  v_phone_digits text;
  v_email_norm text;
begin
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22004';
  end if;
  if p_client_name is null or btrim(p_client_name) = '' then
    raise exception 'client name is required' using errcode = '22004';
  end if;

  v_phone_digits := nullif(pg_catalog.regexp_replace(coalesce(p_client_phone, ''), '[^0-9]', '', 'g'), '');
  v_email_norm := nullif(pg_catalog.lower(btrim(coalesce(p_client_email, ''))), '');
  if v_phone_digits is null and v_email_norm is null then
    raise exception 'phone or email is required' using errcode = '22004';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_request_id::text, 0));

  select * into v_existing
  from public.salon_appointments a
  where a.online_request_id = p_request_id;

  if found then
    if v_existing.organization_id <> p_organization_id then
      raise exception 'request_id already belongs to another salon' using errcode = '23505';
    end if;

    return jsonb_build_object(
      'appointment_id', v_existing.id,
      'organization_id', v_existing.organization_id,
      'unit_id', v_existing.unit_id,
      'service_id', v_existing.service_id,
      'professional_id', v_existing.professional_id,
      'starts_at', v_existing.starts_at,
      'ends_at', v_existing.ends_at,
      'status', v_existing.status,
      'source', v_existing.source,
      'idempotent_replay', true
    );
  end if;

  if not exists (
    select 1 from public.salon_organizations o
    where o.id = p_organization_id and o.status = 'active'
  ) then
    raise exception 'salon is not available for public booking' using errcode = 'P0001';
  end if;

  select c.id into v_client_id
  from public.salon_clients c
  where c.organization_id = p_organization_id
    and c.status = 'active'
    and (
      (v_email_norm is not null and pg_catalog.lower(btrim(coalesce(c.email, ''))) = v_email_norm)
      or
      (v_email_norm is null and v_phone_digits is not null and pg_catalog.regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g') = v_phone_digits)
    )
  order by c.created_at, c.id
  limit 1;

  if v_client_id is null then
    insert into public.salon_clients (
      organization_id, full_name, phone, email, status, created_by
    ) values (
      p_organization_id,
      btrim(p_client_name),
      nullif(btrim(coalesce(p_client_phone, '')), ''),
      nullif(btrim(coalesce(p_client_email, '')), ''),
      'active',
      null
    )
    returning id into v_client_id;
  end if;

  for v_prof in
    select s.professional_id, s.professional_name
    from salon_booking_private.available_slots(
      p_organization_id,
      p_unit_id,
      p_service_id,
      (p_starts_at at time zone (
        select u.timezone from public.salon_units u
        where u.organization_id = p_organization_id and u.id = p_unit_id
      ))::date,
      p_professional_id
    ) s
    where s.starts_at = p_starts_at
    order by s.professional_name, s.professional_id
  loop
    begin
      insert into public.salon_appointments (
        organization_id,
        unit_id,
        client_id,
        service_id,
        professional_id,
        starts_at,
        duration_minutes,
        ends_at,
        status,
        source,
        online_request_id,
        created_by
      ) values (
        p_organization_id,
        p_unit_id,
        v_client_id,
        p_service_id,
        v_prof.professional_id,
        p_starts_at,
        1,
        p_starts_at + interval '1 minute',
        'scheduled',
        'online',
        p_request_id,
        null
      )
      returning * into v_appointment;

      return jsonb_build_object(
        'appointment_id', v_appointment.id,
        'organization_id', v_appointment.organization_id,
        'unit_id', v_appointment.unit_id,
        'service_id', v_appointment.service_id,
        'professional_id', v_appointment.professional_id,
        'professional_name', v_prof.professional_name,
        'starts_at', v_appointment.starts_at,
        'ends_at', v_appointment.ends_at,
        'status', v_appointment.status,
        'source', v_appointment.source,
        'idempotent_replay', false
      );
    exception
      when exclusion_violation or check_violation or foreign_key_violation then
        continue;
      when unique_violation then
        select * into v_existing
        from public.salon_appointments a
        where a.online_request_id = p_request_id;
        if found then
          return jsonb_build_object(
            'appointment_id', v_existing.id,
            'organization_id', v_existing.organization_id,
            'unit_id', v_existing.unit_id,
            'service_id', v_existing.service_id,
            'professional_id', v_existing.professional_id,
            'starts_at', v_existing.starts_at,
            'ends_at', v_existing.ends_at,
            'status', v_existing.status,
            'source', v_existing.source,
            'idempotent_replay', true
          );
        end if;
        continue;
    end;
  end loop;

  raise exception 'selected time is no longer available' using errcode = 'P0001';
end;
$$;

create or replace function public.salon_public_catalog(p_organization_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select salon_booking_private.catalog(p_organization_id);
$$;

create or replace function public.salon_public_available_slots(
  p_organization_id uuid,
  p_unit_id uuid,
  p_service_id uuid,
  p_date date,
  p_professional_id uuid default null
)
returns table (
  starts_at timestamptz,
  ends_at timestamptz,
  professional_id uuid,
  professional_name text
)
language sql
security invoker
set search_path = ''
as $$
  select *
  from salon_booking_private.available_slots(
    p_organization_id,
    p_unit_id,
    p_service_id,
    p_date,
    p_professional_id
  );
$$;

create or replace function public.salon_public_book(
  p_request_id uuid,
  p_organization_id uuid,
  p_unit_id uuid,
  p_service_id uuid,
  p_starts_at timestamptz,
  p_client_name text,
  p_client_phone text default null,
  p_client_email text default null,
  p_professional_id uuid default null
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select salon_booking_private.book(
    p_request_id,
    p_organization_id,
    p_unit_id,
    p_service_id,
    p_starts_at,
    p_client_name,
    p_client_phone,
    p_client_email,
    p_professional_id
  );
$$;

revoke all on all functions in schema salon_booking_private from public, anon, authenticated;
grant usage on schema salon_booking_private to anon, authenticated;
grant execute on function salon_booking_private.catalog(uuid) to anon, authenticated;
grant execute on function salon_booking_private.available_slots(uuid, uuid, uuid, date, uuid) to anon, authenticated;
grant execute on function salon_booking_private.book(uuid, uuid, uuid, uuid, timestamptz, text, text, text, uuid) to anon, authenticated;

revoke all on function public.salon_public_catalog(uuid) from public, anon, authenticated;
revoke all on function public.salon_public_available_slots(uuid, uuid, uuid, date, uuid) from public, anon, authenticated;
revoke all on function public.salon_public_book(uuid, uuid, uuid, uuid, timestamptz, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.salon_public_catalog(uuid) to anon, authenticated;
grant execute on function public.salon_public_available_slots(uuid, uuid, uuid, date, uuid) to anon, authenticated;
grant execute on function public.salon_public_book(uuid, uuid, uuid, uuid, timestamptz, text, text, text, uuid) to anon, authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'salon_appointments'
  ) then
    alter publication supabase_realtime add table public.salon_appointments;
  end if;
end;
$$;