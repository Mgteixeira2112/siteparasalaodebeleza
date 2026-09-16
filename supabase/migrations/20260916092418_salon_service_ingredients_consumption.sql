create table public.salon_service_ingredients (
 organization_id uuid not null,
 service_id uuid not null,
 inventory_item_id uuid not null,
 quantity numeric(14,3) not null check (quantity > 0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key (organization_id, service_id, inventory_item_id),
 constraint salon_service_ingredients_service_fkey foreign key (organization_id, service_id) references public.salon_services (organization_id, id),
 constraint salon_service_ingredients_item_fkey foreign key (organization_id, inventory_item_id) references public.salon_inventory_items (organization_id, id)
);
create index salon_service_ingredients_org_item_fk_idx on public.salon_service_ingredients(organization_id, inventory_item_id);

create function salon_private.validate_service_ingredient() returns trigger language plpgsql set search_path to '' as $$
declare v_item_type text; v_status text;
begin
 select i.item_type, i.status into v_item_type,v_status from public.salon_inventory_items i
 where i.organization_id=new.organization_id and i.id=new.inventory_item_id;
 if not found or v_item_type not in ('consumable','both') or v_status <> 'active' then
  raise exception 'ingredient requires an active consumable inventory item in the same organization' using errcode='23514';
 end if;
 if tg_op='UPDATE' and (new.organization_id is distinct from old.organization_id or new.service_id is distinct from old.service_id or new.inventory_item_id is distinct from old.inventory_item_id or new.created_at is distinct from old.created_at) then
  raise exception 'ingredient identity fields are immutable' using errcode='23514';
 end if;
 return new;
end $$;
revoke all on function salon_private.validate_service_ingredient() from public,anon,authenticated;
create trigger salon_service_ingredients_validate before insert or update on public.salon_service_ingredients for each row execute function salon_private.validate_service_ingredient();
create trigger salon_service_ingredients_touch before update on public.salon_service_ingredients for each row execute function salon_private.touch_updated_at();
alter table public.salon_service_ingredients enable row level security;
create policy "salon members read service ingredients" on public.salon_service_ingredients for select to authenticated using (salon_private.is_active_member(organization_id));
create policy "salon managers insert service ingredients" on public.salon_service_ingredients for insert to authenticated with check (salon_private.has_org_role(organization_id,array['owner','admin','manager']));
create policy "salon managers update service ingredients" on public.salon_service_ingredients for update to authenticated using (salon_private.has_org_role(organization_id,array['owner','admin','manager'])) with check (salon_private.has_org_role(organization_id,array['owner','admin','manager']));
create policy "salon managers remove service ingredients" on public.salon_service_ingredients for delete to authenticated using (salon_private.has_org_role(organization_id,array['owner','admin','manager']));
revoke all on public.salon_service_ingredients from public,anon,authenticated;
grant select, delete on public.salon_service_ingredients to authenticated;
grant insert(organization_id,service_id,inventory_item_id,quantity) on public.salon_service_ingredients to authenticated;
grant update(quantity) on public.salon_service_ingredients to authenticated;

alter table public.salon_inventory_movements add column appointment_id uuid;
alter table public.salon_inventory_movements add constraint salon_inventory_movements_appointment_same_org_fkey foreign key(organization_id,appointment_id) references public.salon_appointments(organization_id,id);
alter table public.salon_inventory_movements add constraint salon_inventory_movements_consumption_origin_check check ((reason='service_consumption') = (appointment_id is not null));
alter table public.salon_inventory_movements add constraint salon_inventory_movements_one_item_per_appointment unique(organization_id,appointment_id,inventory_item_id);

create or replace function salon_private.prepare_inventory_movement() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
 v_item_status text; v_item_cost integer; v_balance numeric(14,3); v_appointment_service uuid;
 v_ingredient_quantity numeric(14,3); v_automatic boolean;
begin
 new.reason := lower(btrim(new.reason));
 new.note := nullif(btrim(new.note), '');
 new.created_by := auth.uid();
 if new.created_by is null then raise exception 'authentication required' using errcode='28000'; end if;
 v_automatic := new.reason='service_consumption';
 if v_automatic then
  if new.appointment_id is null or new.quantity_delta >= 0 or pg_trigger_depth() <> 2 then
   raise exception 'service consumption is reserved for appointment completion' using errcode='23514';
  end if;
  select a.service_id into v_appointment_service from public.salon_appointments a
  where a.organization_id=new.organization_id and a.id=new.appointment_id
  and a.unit_id=new.unit_id and a.status='completed';
  if not found then raise exception 'consumption requires a completed appointment in the same organization and unit' using errcode='23514'; end if;
  select r.quantity into v_ingredient_quantity from public.salon_service_ingredients r
  where r.organization_id=new.organization_id and r.service_id=v_appointment_service and r.inventory_item_id=new.inventory_item_id;
  if not found or new.quantity_delta <> -v_ingredient_quantity then
   raise exception 'consumption does not match the service ingredient' using errcode='23514';
  end if;
 elsif new.appointment_id is not null then
  raise exception 'only automatic service consumption can reference appointment' using errcode='23514';
 end if;
 select i.status,i.unit_cost_cents into v_item_status,v_item_cost from public.salon_inventory_items i
 where i.organization_id=new.organization_id and i.id=new.inventory_item_id for update;
 if not found then raise exception 'inventory item not found' using errcode='P0002'; end if;
 if v_item_status <> 'active' and not v_automatic then raise exception 'inventory item is inactive' using errcode='23514'; end if;
 if new.unit_cost_cents_snapshot is null then new.unit_cost_cents_snapshot := v_item_cost; end if;
 if new.quantity_delta < 0 and not v_automatic then
  select coalesce(sum(m.quantity_delta),0) into v_balance from public.salon_inventory_movements m
  where m.organization_id=new.organization_id and m.unit_id=new.unit_id and m.inventory_item_id=new.inventory_item_id;
  if v_balance+new.quantity_delta < 0 then raise exception 'inventory movement would make stock negative' using errcode='23514'; end if;
 end if;
 return new;
end $$;
revoke all on function salon_private.prepare_inventory_movement() from public,anon,authenticated;

create function salon_private.consume_ingredients_on_completion() returns trigger language plpgsql security definer set search_path to '' as $$
begin
 if new.status='completed' and old.status is distinct from new.status then
  insert into public.salon_inventory_movements(organization_id,unit_id,inventory_item_id,request_id,quantity_delta,reason,appointment_id,created_by)
  select new.organization_id,new.unit_id,r.inventory_item_id,gen_random_uuid(),-r.quantity,'service_consumption',new.id,auth.uid()
  from public.salon_service_ingredients r
  where r.organization_id=new.organization_id and r.service_id=new.service_id
  order by r.inventory_item_id
  on conflict (organization_id,appointment_id,inventory_item_id) do nothing;
 end if;
 return new;
end $$;
revoke all on function salon_private.consume_ingredients_on_completion() from public,anon,authenticated;
create trigger salon_appointments_record_consumption after update of status on public.salon_appointments for each row execute function salon_private.consume_ingredients_on_completion();

create function salon_private.lock_completed_appointment_for_inventory() returns trigger language plpgsql set search_path to '' as $$
begin
 if old.status='completed' and (new.organization_id is distinct from old.organization_id or new.unit_id is distinct from old.unit_id or new.service_id is distinct from old.service_id or new.id is distinct from old.id) then
  raise exception 'completed appointment inventory identity is immutable' using errcode='23514';
 end if;
 return new;
end $$;
revoke all on function salon_private.lock_completed_appointment_for_inventory() from public,anon,authenticated;
create trigger salon_appointments_lock_completed_inventory before update on public.salon_appointments for each row execute function salon_private.lock_completed_appointment_for_inventory();

create view public.salon_service_consumption_costs with (security_invoker=true) as
select m.organization_id,m.appointment_id,m.unit_id,count(*)::integer as ingredient_count,
 count(*) filter (where m.unit_cost_cents_snapshot is null)::integer as missing_cost_count,
 case when count(*) filter (where m.unit_cost_cents_snapshot is null)>0 then null::bigint
 else sum(round(-m.quantity_delta*m.unit_cost_cents_snapshot))::bigint end as cost_cents
from public.salon_inventory_movements m
where m.reason='service_consumption' and m.appointment_id is not null
group by m.organization_id,m.appointment_id,m.unit_id;
revoke all on public.salon_service_consumption_costs from public,anon,authenticated;
grant select on public.salon_service_consumption_costs to authenticated;