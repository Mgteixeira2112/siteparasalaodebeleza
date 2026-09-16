-- PC2: walk-in retail comandas reuse existing sales, stock and payment flows.
-- Appointment comandas retain mandatory appointment/client and stay trigger-created.
alter table public.salon_comandas
  alter column appointment_id drop not null,
  alter column client_id drop not null;

alter table public.salon_comandas add column request_id uuid;
alter table public.salon_comandas
  add constraint salon_comandas_origin_check check (
    (appointment_id is not null and client_id is not null and request_id is null)
    or
    (appointment_id is null and request_id is not null and created_by is not null)
  );
alter table public.salon_comandas
  add constraint salon_comandas_walkin_request_unique unique (organization_id, request_id);

create function salon_private.prepare_walkin_comanda()
returns trigger language plpgsql security invoker set search_path to '' as $$
declare
  v_org_status text;
  v_unit_status text;
  v_client_status text;
begin
  -- Automatic appointment comandas remain handled by their existing completion trigger.
  if new.appointment_id is not null then
    return new;
  end if;
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if new.request_id is null then
    raise exception 'request_id is required for walk-in comanda' using errcode = '23514';
  end if;
  select o.status into v_org_status
    from public.salon_organizations o where o.id = new.organization_id;
  if not found or v_org_status <> 'active' then
    raise exception 'organization must be active' using errcode = '23514';
  end if;
  select u.status into v_unit_status
    from public.salon_units u
   where u.organization_id = new.organization_id and u.id = new.unit_id;
  if not found or v_unit_status <> 'active' then
    raise exception 'unit must be active and belong to organization' using errcode = '23514';
  end if;
  if new.client_id is not null then
    select c.status into v_client_status
      from public.salon_clients c
     where c.organization_id = new.organization_id and c.id = new.client_id;
    if not found or v_client_status <> 'active' then
      raise exception 'client must be active and belong to organization' using errcode = '23514';
    end if;
  end if;
  new.created_by := auth.uid();
  return new;
end $$;
revoke all on function salon_private.prepare_walkin_comanda() from public, anon, authenticated;
create trigger salon_comandas_prepare_walkin
before insert on public.salon_comandas for each row
execute function salon_private.prepare_walkin_comanda();

create policy "salon cashiers open walkin comandas"
on public.salon_comandas for insert to authenticated
with check (
  appointment_id is null and request_id is not null
  and created_by = (select auth.uid())
  and salon_private.has_org_role(organization_id, array['owner','admin','manager','receptionist','cashier'])
);
-- No client data, paid status, creator, or appointment linkage may be supplied by a caller.
grant insert (organization_id, unit_id, client_id, request_id)
on public.salon_comandas to authenticated;

create function public.salon_open_walkin_comanda(
  p_organization_id uuid,
  p_unit_id uuid,
  p_request_id uuid,
  p_client_id uuid default null
)
returns table(comanda_id uuid, comanda_status text, idempotent_replay boolean)
language plpgsql security invoker set search_path to '' as $$
declare
  v_comanda public.salon_comandas;
  v_created boolean := false;
begin
  if auth.uid() is null
     or not salon_private.has_org_role(p_organization_id, array['owner','admin','manager','receptionist','cashier']) then
    raise exception 'not authorized to open walk-in comanda' using errcode = '42501';
  end if;
  if p_request_id is null or p_unit_id is null then
    raise exception 'unit_id and request_id are required' using errcode = '23514';
  end if;

  select c.* into v_comanda
    from public.salon_comandas c
   where c.organization_id = p_organization_id and c.request_id = p_request_id;
  if not found then
    insert into public.salon_comandas(organization_id, unit_id, client_id, request_id)
    values(p_organization_id, p_unit_id, p_client_id, p_request_id)
    on conflict (organization_id, request_id) do nothing
    returning * into v_comanda;
    v_created := v_comanda.id is not null;
    if not v_created then
      select c.* into v_comanda
        from public.salon_comandas c
       where c.organization_id = p_organization_id and c.request_id = p_request_id;
    end if;
  end if;
  if v_comanda.id is null then
    raise exception 'unable to open walk-in comanda' using errcode = 'P0002';
  end if;
  if v_comanda.appointment_id is not null
     or v_comanda.unit_id is distinct from p_unit_id
     or v_comanda.client_id is distinct from p_client_id then
    raise exception 'idempotency key reused with different walk-in payload' using errcode = '23514';
  end if;
  return query select v_comanda.id, v_comanda.status, not v_created;
end $$;
revoke all on function public.salon_open_walkin_comanda(uuid,uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.salon_open_walkin_comanda(uuid,uuid,uuid,uuid) to authenticated;
