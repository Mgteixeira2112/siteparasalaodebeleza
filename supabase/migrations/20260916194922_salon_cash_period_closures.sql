-- Cash closes reconcile immutable receipts by unit and period; no parallel cash balance.
create table public.salon_cash_closures (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.salon_organizations(id),
 unit_id uuid not null,
 request_id uuid not null,
 period_start timestamptz,
 period_end timestamptz not null default now(),
 business_date date not null default current_date,
 timezone_snapshot text not null default 'America/Sao_Paulo',
 payment_count bigint not null default 0 check (payment_count > 0),
 total_cents bigint not null default 0 check (total_cents > 0),
 method_totals_cents jsonb not null default '{}'::jsonb check (jsonb_typeof(method_totals_cents) = 'object'),
 closed_by uuid not null references auth.users(id),
 closed_at timestamptz not null default now(),
 created_at timestamptz not null default now(),
 constraint salon_cash_closures_org_unit_fk foreign key (organization_id,unit_id) references public.salon_units(organization_id,id),
 constraint salon_cash_closures_request_uniq unique (organization_id,request_id),
 constraint salon_cash_closures_period_check check (period_start is null or period_end > period_start),
 constraint salon_cash_closures_cutoff_check check (period_end = closed_at)
);
create index salon_cash_closures_org_unit_period_idx on public.salon_cash_closures(organization_id,unit_id,period_end desc);
create index salon_cash_closures_closed_by_idx on public.salon_cash_closures(closed_by);
alter table public.salon_cash_closures enable row level security;
revoke all on public.salon_cash_closures from public,anon,authenticated;
grant select on public.salon_cash_closures to authenticated;
grant insert (organization_id,unit_id,request_id) on public.salon_cash_closures to authenticated;
create policy "salon members read cash closures" on public.salon_cash_closures for select to authenticated using (salon_private.is_active_member(organization_id));
create policy "salon cash roles close periods" on public.salon_cash_closures for insert to authenticated with check (closed_by = (select auth.uid()) and salon_private.has_org_role(organization_id,array['owner','admin','manager','cashier']));

-- Appending a closure creates a server-authored immutable reconciliation snapshot.
create function salon_private.prepare_cash_closure() returns trigger language plpgsql security invoker set search_path to '' as $$
declare v_timezone text; v_previous timestamptz; v_count bigint; v_total bigint;
begin
 if auth.uid() is null or not salon_private.has_org_role(new.organization_id,array['owner','admin','manager','cashier']) then
   raise exception 'not authorized to close cash period' using errcode='42501';
 end if;
 if new.request_id is null then raise exception 'request_id required' using errcode='23514'; end if;
 select u.timezone into v_timezone from public.salon_units u where u.organization_id=new.organization_id and u.id=new.unit_id;
 if not found then raise exception 'unit not found' using errcode='P0002'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(new.organization_id::text),pg_catalog.hashtext(new.unit_id::text));
 select c.period_end into v_previous from public.salon_cash_closures c where c.organization_id=new.organization_id and c.unit_id=new.unit_id order by c.period_end desc limit 1;
 new.period_start:=v_previous;
 new.period_end:=pg_catalog.clock_timestamp();
 new.closed_at:=new.period_end;
 new.created_at:=new.period_end;
 new.business_date:=(new.closed_at at time zone v_timezone)::date;
 new.timezone_snapshot:=v_timezone;
 new.closed_by:=auth.uid();
 select count(*),coalesce(sum(p.amount_cents),0) into v_count,v_total
 from public.salon_payments p join public.salon_comandas c on c.organization_id=p.organization_id and c.id=p.comanda_id
 where p.organization_id=new.organization_id and c.unit_id=new.unit_id
   and (v_previous is null or p.paid_at > v_previous) and p.paid_at <= new.period_end;
 if v_count=0 then raise exception 'no unclosed payments for this unit' using errcode='23514'; end if;
 new.payment_count:=v_count;
 new.total_cents:=v_total;
 select coalesce(jsonb_object_agg(method,method_total),'{}'::jsonb) into new.method_totals_cents from (
   select p.method,sum(p.amount_cents)::bigint method_total
   from public.salon_payments p join public.salon_comandas c on c.organization_id=p.organization_id and c.id=p.comanda_id
   where p.organization_id=new.organization_id and c.unit_id=new.unit_id
     and (v_previous is null or p.paid_at > v_previous) and p.paid_at <= new.period_end
   group by p.method
 ) methods;
 return new;
end $$;
revoke all on function salon_private.prepare_cash_closure() from public,anon,authenticated;
create trigger salon_cash_closures_prepare before insert on public.salon_cash_closures for each row execute function salon_private.prepare_cash_closure();
create function salon_private.reject_cash_closure_edits() returns trigger language plpgsql security invoker set search_path to '' as $$
begin raise exception 'cash closures are immutable' using errcode='23514'; end $$;
revoke all on function salon_private.reject_cash_closure_edits() from public,anon,authenticated;
create trigger salon_cash_closures_immutable before update or delete on public.salon_cash_closures for each row execute function salon_private.reject_cash_closure_edits();

-- Receipt time is assigned after acquiring the same unit-level lock used by closure.
create or replace function salon_private.validate_payment() returns trigger language plpgsql security definer set search_path to '' as $$
declare v_status text; v_unit uuid; v_total bigint; v_paid bigint; v_balance bigint;
begin
 new.method:=lower(btrim(new.method));
 new.received_by:=auth.uid();
 if new.received_by is null or not salon_private.has_org_role(new.organization_id,array['owner','admin','manager','receptionist','cashier']) then
  raise exception 'not authorized to receive payment' using errcode='42501';
 end if;
 select c.status,c.unit_id into v_status,v_unit from public.salon_comandas c where c.organization_id=new.organization_id and c.id=new.comanda_id for update;
 if not found then raise exception 'comanda not found' using errcode='P0002'; end if;
 if v_status<>'open' then raise exception 'comanda is not open' using errcode='23514'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(new.organization_id::text),pg_catalog.hashtext(v_unit::text));
 new.paid_at:=pg_catalog.clock_timestamp();
 new.created_at:=new.paid_at;
 select coalesce((select sum(i.total_price_cents) from public.salon_comanda_items i where i.organization_id=new.organization_id and i.comanda_id=new.comanda_id),0)
       +coalesce((select sum(r.total_price_cents) from public.salon_comanda_retail_items r where r.organization_id=new.organization_id and r.comanda_id=new.comanda_id),0)
 into v_total;
 select coalesce(sum(p.amount_cents),0) into v_paid from public.salon_payments p where p.organization_id=new.organization_id and p.comanda_id=new.comanda_id;
 v_balance:=v_total-v_paid;
 if v_balance<=0 then raise exception 'comanda has no outstanding balance' using errcode='23514'; end if;
 if new.amount_cents>v_balance then raise exception 'payment exceeds outstanding balance' using errcode='23514'; end if;
 return new;
end $$;

-- The only public close endpoint operates with caller privileges and existing RLS.
create function public.salon_close_cash_period(p_organization_id uuid,p_unit_id uuid,p_request_id uuid)
returns table(closure_id uuid,closed_at timestamptz,payment_count bigint,total_cents bigint,method_totals_cents jsonb,idempotent_replay boolean)
language plpgsql security invoker set search_path to '' as $$
declare v_close public.salon_cash_closures; v_replay boolean:=false;
begin
 if auth.uid() is null or not salon_private.has_org_role(p_organization_id,array['owner','admin','manager','cashier']) then
   raise exception 'not authorized to close cash period' using errcode='42501';
 end if;
 if p_unit_id is null or p_request_id is null then raise exception 'unit_id and request_id required' using errcode='23514'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(p_organization_id::text),pg_catalog.hashtext(p_unit_id::text));
 select c.* into v_close from public.salon_cash_closures c where c.organization_id=p_organization_id and c.request_id=p_request_id;
 if found then
  if v_close.unit_id is distinct from p_unit_id then raise exception 'idempotency key reused with different closure payload' using errcode='23514'; end if;
  v_replay:=true;
 else
  insert into public.salon_cash_closures(organization_id,unit_id,request_id) values(p_organization_id,p_unit_id,p_request_id) returning * into v_close;
 end if;
 return query select v_close.id,v_close.closed_at,v_close.payment_count,v_close.total_cents,v_close.method_totals_cents,v_replay;
end $$;
revoke all on function public.salon_close_cash_period(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.salon_close_cash_period(uuid,uuid,uuid) to authenticated;