create or replace function public.salon_post_inventory_movement(
  p_organization_id uuid,
  p_unit_id uuid,
  p_inventory_item_id uuid,
  p_quantity_delta numeric,
  p_reason text,
  p_request_id uuid,
  p_note text default null,
  p_unit_cost_cents_snapshot integer default null
)
returns table (
  movement_id uuid,
  quantity_on_hand numeric(14,3)
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_movement public.salon_inventory_movements;
  v_reason text := lower(btrim(p_reason));
begin
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '23514';
  end if;

  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'quantity_delta must be non-zero' using errcode = '23514';
  end if;

  if v_reason not in ('opening','purchase','adjustment','service_consumption','retail_sale','return') then
    raise exception 'invalid inventory movement reason' using errcode = '23514';
  end if;

  select m.*
    into v_movement
    from public.salon_inventory_movements m
   where m.organization_id = p_organization_id
     and m.request_id = p_request_id;

  if found then
    if v_movement.unit_id <> p_unit_id
       or v_movement.inventory_item_id <> p_inventory_item_id
       or v_movement.quantity_delta <> p_quantity_delta
       or v_movement.reason <> v_reason
       or (p_unit_cost_cents_snapshot is not null
           and v_movement.unit_cost_cents_snapshot is distinct from p_unit_cost_cents_snapshot) then
      raise exception 'idempotency key reused with different inventory payload' using errcode = '23514';
    end if;
  else
    insert into public.salon_inventory_movements(
      organization_id, unit_id, inventory_item_id, request_id,
      quantity_delta, reason, unit_cost_cents_snapshot, note, created_by
    ) values (
      p_organization_id, p_unit_id, p_inventory_item_id, p_request_id,
      p_quantity_delta, v_reason, p_unit_cost_cents_snapshot, p_note, (select auth.uid())
    )
    on conflict (organization_id, request_id) do nothing
    returning * into v_movement;

    if v_movement.id is null then
      select m.*
        into v_movement
        from public.salon_inventory_movements m
       where m.organization_id = p_organization_id
         and m.request_id = p_request_id;

      if v_movement.unit_id <> p_unit_id
         or v_movement.inventory_item_id <> p_inventory_item_id
         or v_movement.quantity_delta <> p_quantity_delta
         or v_movement.reason <> v_reason
         or (p_unit_cost_cents_snapshot is not null
             and v_movement.unit_cost_cents_snapshot is distinct from p_unit_cost_cents_snapshot) then
        raise exception 'idempotency key reused with different inventory payload' using errcode = '23514';
      end if;
    end if;
  end if;

  return query
  select v_movement.id,
         coalesce((
           select sum(m.quantity_delta)::numeric(14,3)
             from public.salon_inventory_movements m
            where m.organization_id = p_organization_id
              and m.unit_id = p_unit_id
              and m.inventory_item_id = p_inventory_item_id
         ), 0::numeric(14,3));
end;
$$;

revoke execute on function public.salon_post_inventory_movement(uuid, uuid, uuid, numeric, text, uuid, text, integer) from public, anon;
grant execute on function public.salon_post_inventory_movement(uuid, uuid, uuid, numeric, text, uuid, text, integer) to authenticated;
