create table public.salon_inventory_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  name text not null check (length(btrim(name)) > 0),
  sku text,
  item_type text not null default 'consumable' check (item_type in ('consumable','retail','both')),
  unit_of_measure text not null default 'unit' check (length(btrim(unit_of_measure)) > 0),
  unit_cost_cents integer check (unit_cost_cents is null or unit_cost_cents >= 0),
  status text not null default 'active' check (status in ('active','inactive')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);

create unique index salon_inventory_items_org_sku_key
  on public.salon_inventory_items(organization_id, lower(sku))
  where sku is not null and btrim(sku) <> '';
create index salon_inventory_items_org_status_idx
  on public.salon_inventory_items(organization_id, status, name);
create index salon_inventory_items_created_by_idx
  on public.salon_inventory_items(created_by);

create table public.salon_inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  unit_id uuid not null,
  inventory_item_id uuid not null,
  request_id uuid not null,
  quantity_delta numeric(14,3) not null check (quantity_delta <> 0),
  reason text not null check (reason in ('opening','purchase','adjustment','service_consumption','retail_sale','return')),
  unit_cost_cents_snapshot integer check (unit_cost_cents_snapshot is null or unit_cost_cents_snapshot >= 0),
  note text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, request_id),
  foreign key (organization_id, unit_id) references public.salon_units(organization_id, id),
  foreign key (organization_id, inventory_item_id) references public.salon_inventory_items(organization_id, id)
);

create index salon_inventory_movements_org_unit_item_idx
  on public.salon_inventory_movements(organization_id, unit_id, inventory_item_id, created_at);
create index salon_inventory_movements_created_by_idx
  on public.salon_inventory_movements(created_by);

alter table public.salon_inventory_items enable row level security;
alter table public.salon_inventory_movements enable row level security;

create policy "salon members read inventory items"
on public.salon_inventory_items for select
to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon inventory managers insert items"
on public.salon_inventory_items for insert
to authenticated
with check (
  salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[])
  and created_by = (select auth.uid())
);

create policy "salon inventory managers update items"
on public.salon_inventory_items for update
to authenticated
using (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]))
with check (salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[]));

create policy "salon members read inventory movements"
on public.salon_inventory_movements for select
to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon inventory managers insert movements"
on public.salon_inventory_movements for insert
to authenticated
with check (
  salon_private.has_org_role(organization_id, array['owner','admin','manager']::text[])
  and created_by = (select auth.uid())
);

revoke all on table public.salon_inventory_items from anon, authenticated;
revoke all on table public.salon_inventory_movements from anon, authenticated;
grant select, insert, update on table public.salon_inventory_items to authenticated;
grant select, insert on table public.salon_inventory_movements to authenticated;

create trigger salon_inventory_items_touch_updated_at
before update on public.salon_inventory_items
for each row execute function salon_private.touch_updated_at();

create or replace function salon_private.prepare_inventory_item()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  new.unit_of_measure := lower(btrim(new.unit_of_measure));
  new.sku := nullif(btrim(new.sku), '');

  if tg_op = 'INSERT' then
    new.created_by := (select auth.uid());
    if new.created_by is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'inventory item identity fields are immutable' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create trigger salon_inventory_items_prepare
before insert or update on public.salon_inventory_items
for each row execute function salon_private.prepare_inventory_item();

create or replace function salon_private.prepare_inventory_movement()
returns trigger
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_item_status text;
  v_item_cost integer;
  v_balance numeric(14,3);
begin
  new.reason := lower(btrim(new.reason));
  new.note := nullif(btrim(new.note), '');
  new.created_by := auth.uid();

  if new.created_by is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select i.status, i.unit_cost_cents
    into v_item_status, v_item_cost
    from public.salon_inventory_items i
   where i.organization_id = new.organization_id
     and i.id = new.inventory_item_id
   for update;

  if not found then
    raise exception 'inventory item not found' using errcode = 'P0002';
  end if;

  if v_item_status <> 'active' then
    raise exception 'inventory item is inactive' using errcode = '23514';
  end if;

  if new.unit_cost_cents_snapshot is null then
    new.unit_cost_cents_snapshot := v_item_cost;
  end if;

  if new.quantity_delta < 0 then
    select coalesce(sum(m.quantity_delta), 0)
      into v_balance
      from public.salon_inventory_movements m
     where m.organization_id = new.organization_id
       and m.unit_id = new.unit_id
       and m.inventory_item_id = new.inventory_item_id;

    if v_balance + new.quantity_delta < 0 then
      raise exception 'inventory movement would make stock negative' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function salon_private.prepare_inventory_movement() from public, anon, authenticated;

create trigger salon_inventory_movements_prepare
before insert on public.salon_inventory_movements
for each row execute function salon_private.prepare_inventory_movement();

create or replace function salon_private.reject_inventory_movement_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'inventory movements are append-only' using errcode = '23514';
end;
$$;

create trigger salon_inventory_movements_append_only
before update or delete on public.salon_inventory_movements
for each row execute function salon_private.reject_inventory_movement_mutation();

create or replace view public.salon_inventory_balances
with (security_invoker = true)
as
select
  m.organization_id,
  m.unit_id,
  m.inventory_item_id,
  sum(m.quantity_delta)::numeric(14,3) as quantity_on_hand,
  max(m.created_at) as last_movement_at
from public.salon_inventory_movements m
group by m.organization_id, m.unit_id, m.inventory_item_id;

revoke all on public.salon_inventory_balances from anon, authenticated;
grant select on public.salon_inventory_balances to authenticated;

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
       or v_movement.unit_cost_cents_snapshot is distinct from p_unit_cost_cents_snapshot then
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
         or v_movement.unit_cost_cents_snapshot is distinct from p_unit_cost_cents_snapshot then
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
