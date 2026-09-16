-- PC2: one retail sale line is one immutable stock movement, attached to an existing comanda.
alter table public.salon_inventory_items add column retail_price_cents integer check (retail_price_cents > 0);

create table public.salon_comanda_retail_items (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 comanda_id uuid not null,
 unit_id uuid not null,
 inventory_item_id uuid not null,
 request_id uuid not null,
 quantity integer not null check (quantity between 1 and 1000),
 description text not null check (length(btrim(description)) > 0),
 unit_price_cents integer not null check (unit_price_cents > 0),
 total_price_cents bigint generated always as (quantity::bigint * unit_price_cents::bigint) stored,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique (organization_id, id),
 unique (organization_id, request_id),
 constraint salon_retail_line_comanda_fkey foreign key (organization_id, comanda_id) references public.salon_comandas(organization_id, id),
 constraint salon_retail_line_unit_fkey foreign key (organization_id, unit_id) references public.salon_units(organization_id, id),
 constraint salon_retail_line_inventory_fkey foreign key (organization_id, inventory_item_id) references public.salon_inventory_items(organization_id, id)
);
create index salon_retail_line_comanda_idx on public.salon_comanda_retail_items(organization_id, comanda_id);
create index salon_retail_line_unit_idx on public.salon_comanda_retail_items(organization_id, unit_id);
create index salon_retail_line_inventory_idx on public.salon_comanda_retail_items(organization_id, inventory_item_id);
create index salon_retail_line_actor_idx on public.salon_comanda_retail_items(created_by);

create function salon_private.prepare_retail_line() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_comanda_status text; v_unit_id uuid; v_item_name text; v_item_type text; v_item_status text; v_retail_price integer;
begin
 if (select auth.uid()) is null then raise exception 'authentication required' using errcode='28000'; end if;
 select c.status,c.unit_id into v_comanda_status,v_unit_id from public.salon_comandas c
 where c.organization_id=new.organization_id and c.id=new.comanda_id for update;
 if not found then raise exception 'comanda not found' using errcode='P0002'; end if;
 if v_comanda_status <> 'open' then raise exception 'comanda is not open' using errcode='23514'; end if;
 select i.name,i.item_type,i.status,i.retail_price_cents into v_item_name,v_item_type,v_item_status,v_retail_price
 from public.salon_inventory_items i where i.organization_id=new.organization_id and i.id=new.inventory_item_id for update;
 if not found or v_item_type not in ('retail','both') or v_item_status <> 'active' or v_retail_price is null then
  raise exception 'retail sale requires active retail item with configured price in the same organization' using errcode='23514';
 end if;
 new.unit_id := v_unit_id;
 new.description := v_item_name;
 new.unit_price_cents := v_retail_price;
 new.created_by := (select auth.uid());
 return new;
end $$;
revoke all on function salon_private.prepare_retail_line() from public,anon,authenticated;
create trigger salon_retail_line_prepare before insert on public.salon_comanda_retail_items for each row execute function salon_private.prepare_retail_line();

create function salon_private.reject_retail_line_mutation() returns trigger language plpgsql set search_path to '' as $$
begin raise exception 'retail sale history is immutable' using errcode='55000'; end $$;
revoke all on function salon_private.reject_retail_line_mutation() from public,anon,authenticated;
create trigger salon_retail_line_append_only before update or delete on public.salon_comanda_retail_items for each row execute function salon_private.reject_retail_line_mutation();
alter table public.salon_comanda_retail_items enable row level security;
create policy "salon members read retail sale lines" on public.salon_comanda_retail_items for select to authenticated using (salon_private.is_active_member(organization_id));
create policy "salon cashiers insert retail sale lines" on public.salon_comanda_retail_items for insert to authenticated with check (salon_private.has_org_role(organization_id,array['owner','admin','manager','receptionist','cashier']) and created_by=(select auth.uid()));
revoke all on public.salon_comanda_retail_items from public,anon,authenticated;
grant select on public.salon_comanda_retail_items to authenticated;
grant insert(organization_id,comanda_id,inventory_item_id,request_id,quantity) on public.salon_comanda_retail_items to authenticated;

alter table public.salon_inventory_movements add column retail_line_id uuid;
alter table public.salon_inventory_movements add constraint salon_movements_retail_origin_check check ((reason='retail_sale') = (retail_line_id is not null));
alter table public.salon_inventory_movements add constraint salon_movements_retail_line_fkey foreign key(organization_id,retail_line_id) references public.salon_comanda_retail_items(organization_id,id);
alter table public.salon_inventory_movements add constraint salon_movements_retail_once unique (organization_id,retail_line_id);

create or replace function salon_private.prepare_inventory_movement() returns trigger language plpgsql security definer set search_path to '' as $$
declare
 v_item_status text; v_item_cost integer; v_balance numeric(14,3); v_appointment_service uuid;
 v_ingredient_quantity numeric(14,3); v_service_auto boolean; v_retail_auto boolean;
 v_sold_quantity integer;
begin
 new.reason := lower(btrim(new.reason));
 new.note := nullif(btrim(new.note), '');
 new.created_by := auth.uid();
 if new.created_by is null then raise exception 'authentication required' using errcode='28000'; end if;
 v_service_auto := new.reason='service_consumption';
 v_retail_auto := new.reason='retail_sale';
 if v_service_auto then
  if new.appointment_id is null or new.retail_line_id is not null or new.quantity_delta >= 0 or pg_trigger_depth() <> 2 then
   raise exception 'service consumption is reserved for appointment completion' using errcode='23514';
  end if;
  select a.service_id into v_appointment_service from public.salon_appointments a
  where a.organization_id=new.organization_id and a.id=new.appointment_id and a.unit_id=new.unit_id and a.status='completed';
  if not found then raise exception 'consumption requires completed appointment in same organization and unit' using errcode='23514'; end if;
  select r.quantity into v_ingredient_quantity from public.salon_service_ingredients r
  where r.organization_id=new.organization_id and r.service_id=v_appointment_service and r.inventory_item_id=new.inventory_item_id;
  if not found or new.quantity_delta <> -v_ingredient_quantity then raise exception 'consumption does not match service ingredient' using errcode='23514'; end if;
 elsif v_retail_auto then
  if new.retail_line_id is null or new.appointment_id is not null or new.quantity_delta >= 0 or pg_trigger_depth() <> 2 then
   raise exception 'retail stock movement is reserved for comanda sale' using errcode='23514';
  end if;
  select r.quantity into v_sold_quantity from public.salon_comanda_retail_items r
  join public.salon_comandas c on c.organization_id=r.organization_id and c.id=r.comanda_id
  where r.organization_id=new.organization_id and r.id=new.retail_line_id and r.unit_id=new.unit_id
    and r.inventory_item_id=new.inventory_item_id and c.status='open';
  if not found or new.quantity_delta <> -v_sold_quantity then raise exception 'retail stock movement does not match open comanda sale' using errcode='23514'; end if;
 elsif new.appointment_id is not null or new.retail_line_id is not null then
  raise exception 'manual inventory movement cannot reference sale or appointment' using errcode='23514';
 end if;
 select i.status,i.unit_cost_cents into v_item_status,v_item_cost from public.salon_inventory_items i
 where i.organization_id=new.organization_id and i.id=new.inventory_item_id for update;
 if not found then raise exception 'inventory item not found' using errcode='P0002'; end if;
 if v_item_status <> 'active' and not v_service_auto then raise exception 'inventory item is inactive' using errcode='23514'; end if;
 if new.unit_cost_cents_snapshot is null then new.unit_cost_cents_snapshot := v_item_cost; end if;
 if new.quantity_delta < 0 and not v_service_auto then
  select coalesce(sum(m.quantity_delta),0) into v_balance from public.salon_inventory_movements m
  where m.organization_id=new.organization_id and m.unit_id=new.unit_id and m.inventory_item_id=new.inventory_item_id;
  if v_balance+new.quantity_delta < 0 then raise exception 'inventory movement would make stock negative' using errcode='23514'; end if;
 end if;
 return new;
end $$;
revoke all on function salon_private.prepare_inventory_movement() from public,anon,authenticated;

create function salon_private.post_retail_stock_movement() returns trigger language plpgsql security definer set search_path to '' as $$
begin
 insert into public.salon_inventory_movements(organization_id,unit_id,inventory_item_id,request_id,quantity_delta,reason,retail_line_id,created_by)
 values(new.organization_id,new.unit_id,new.inventory_item_id,gen_random_uuid(),-new.quantity,'retail_sale',new.id,auth.uid());
 return new;
end $$;
revoke all on function salon_private.post_retail_stock_movement() from public,anon,authenticated;
create trigger salon_retail_line_post_stock after insert on public.salon_comanda_retail_items for each row execute function salon_private.post_retail_stock_movement();

create or replace function salon_private.validate_payment() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_status text; v_total bigint; v_paid bigint; v_balance bigint;
begin
 new.method := lower(btrim(new.method)); new.received_by := auth.uid();
 if new.received_by is null then raise exception 'authentication required' using errcode='28000'; end if;
 select c.status into v_status from public.salon_comandas c where c.organization_id=new.organization_id and c.id=new.comanda_id for update;
 if not found then raise exception 'comanda not found' using errcode='P0002'; end if;
 if v_status<>'open' then raise exception 'comanda is not open' using errcode='23514'; end if;
 select coalesce((select sum(i.total_price_cents) from public.salon_comanda_items i where i.organization_id=new.organization_id and i.comanda_id=new.comanda_id),0)
       +coalesce((select sum(r.total_price_cents) from public.salon_comanda_retail_items r where r.organization_id=new.organization_id and r.comanda_id=new.comanda_id),0)
 into v_total;
 select coalesce(sum(p.amount_cents),0) into v_paid from public.salon_payments p where p.organization_id=new.organization_id and p.comanda_id=new.comanda_id;
 v_balance:=v_total-v_paid;
 if v_balance<=0 then raise exception 'comanda has no outstanding balance' using errcode='23514'; end if;
 if new.amount_cents>v_balance then raise exception 'payment exceeds outstanding balance' using errcode='23514'; end if;
 return new;
end $$;
revoke all on function salon_private.validate_payment() from public,anon,authenticated;

create or replace function salon_private.close_comanda_after_payment() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_total bigint; v_paid bigint;
begin
 select coalesce((select sum(i.total_price_cents) from public.salon_comanda_items i where i.organization_id=new.organization_id and i.comanda_id=new.comanda_id),0)
       +coalesce((select sum(r.total_price_cents) from public.salon_comanda_retail_items r where r.organization_id=new.organization_id and r.comanda_id=new.comanda_id),0)
 into v_total;
 select coalesce(sum(p.amount_cents),0) into v_paid from public.salon_payments p where p.organization_id=new.organization_id and p.comanda_id=new.comanda_id;
 if v_total>0 and v_paid=v_total then
  update public.salon_comandas set status='paid',paid_at=new.paid_at where organization_id=new.organization_id and id=new.comanda_id and status='open';
 end if;
 return new;
end $$;
revoke all on function salon_private.close_comanda_after_payment() from public,anon,authenticated;

create or replace function public.salon_pay_comanda(p_organization_id uuid,p_comanda_id uuid,p_amount_cents integer,p_method text,p_request_id uuid)
returns table(payment_id uuid,comanda_status text,total_cents bigint,paid_cents bigint,balance_cents bigint)
language plpgsql security invoker set search_path to '' as $$
declare v_payment public.salon_payments; v_method text:=lower(btrim(p_method));
begin
 if p_request_id is null then raise exception 'request_id is required' using errcode='23514'; end if;
 select p.* into v_payment from public.salon_payments p where p.organization_id=p_organization_id and p.request_id=p_request_id;
 if found then
  if v_payment.comanda_id<>p_comanda_id or v_payment.amount_cents<>p_amount_cents or v_payment.method<>v_method then
   raise exception 'idempotency key reused with different payment payload' using errcode='23514';
  end if;
 else
  insert into public.salon_payments(organization_id,comanda_id,request_id,amount_cents,method,received_by)
  values(p_organization_id,p_comanda_id,p_request_id,p_amount_cents,v_method,auth.uid())
  on conflict(organization_id,request_id) do nothing returning * into v_payment;
  if v_payment.id is null then
   select p.* into v_payment from public.salon_payments p where p.organization_id=p_organization_id and p.request_id=p_request_id;
   if v_payment.comanda_id<>p_comanda_id or v_payment.amount_cents<>p_amount_cents or v_payment.method<>v_method then
    raise exception 'idempotency key reused with different payment payload' using errcode='23514';
   end if;
  end if;
 end if;
 return query
 select v_payment.id,c.status,s.service_total+r.retail_total,
        p.total_paid,s.service_total+r.retail_total-p.total_paid
 from public.salon_comandas c
 cross join lateral (select coalesce(sum(i.total_price_cents),0)::bigint service_total from public.salon_comanda_items i where i.organization_id=c.organization_id and i.comanda_id=c.id) s
 cross join lateral (select coalesce(sum(i.total_price_cents),0)::bigint retail_total from public.salon_comanda_retail_items i where i.organization_id=c.organization_id and i.comanda_id=c.id) r
 cross join lateral (select coalesce(sum(i.amount_cents),0)::bigint total_paid from public.salon_payments i where i.organization_id=c.organization_id and i.comanda_id=c.id) p
 where c.organization_id=p_organization_id and c.id=p_comanda_id;
end $$;
revoke all on function public.salon_pay_comanda(uuid,uuid,integer,text,uuid) from public,anon;
grant execute on function public.salon_pay_comanda(uuid,uuid,integer,text,uuid) to authenticated;

create function public.salon_sell_retail_product(p_organization_id uuid,p_comanda_id uuid,p_inventory_item_id uuid,p_quantity integer,p_request_id uuid)
returns table(retail_line_id uuid,unit_price_cents integer,line_total_cents bigint,quantity_on_hand numeric)
language plpgsql security invoker set search_path to '' as $$
declare v_line public.salon_comanda_retail_items;
begin
 if p_request_id is null then raise exception 'request_id is required' using errcode='23514'; end if;
 if p_quantity is null or p_quantity not between 1 and 1000 then raise exception 'retail quantity must be 1 to 1000' using errcode='23514'; end if;
 select r.* into v_line from public.salon_comanda_retail_items r where r.organization_id=p_organization_id and r.request_id=p_request_id;
 if found then
  if v_line.comanda_id<>p_comanda_id or v_line.inventory_item_id<>p_inventory_item_id or v_line.quantity<>p_quantity then
   raise exception 'idempotency key reused with different retail payload' using errcode='23514';
  end if;
 else
  insert into public.salon_comanda_retail_items(organization_id,comanda_id,inventory_item_id,quantity,request_id)
  values(p_organization_id,p_comanda_id,p_inventory_item_id,p_quantity,p_request_id)
  on conflict(organization_id,request_id) do nothing returning * into v_line;
  if v_line.id is null then
   select r.* into v_line from public.salon_comanda_retail_items r where r.organization_id=p_organization_id and r.request_id=p_request_id;
   if v_line.comanda_id<>p_comanda_id or v_line.inventory_item_id<>p_inventory_item_id or v_line.quantity<>p_quantity then
    raise exception 'idempotency key reused with different retail payload' using errcode='23514';
   end if;
  end if;
 end if;
 return query select v_line.id,v_line.unit_price_cents,v_line.total_price_cents,
  coalesce((select sum(m.quantity_delta)::numeric(14,3) from public.salon_inventory_movements m
    where m.organization_id=v_line.organization_id and m.unit_id=v_line.unit_id and m.inventory_item_id=v_line.inventory_item_id),0::numeric(14,3));
end $$;
revoke all on function public.salon_sell_retail_product(uuid,uuid,uuid,integer,uuid) from public,anon;
grant execute on function public.salon_sell_retail_product(uuid,uuid,uuid,integer,uuid) to authenticated;
