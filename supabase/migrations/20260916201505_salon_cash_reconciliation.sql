alter table public.salon_cash_closures
  add constraint salon_cash_closures_org_id_uniq unique (organization_id, id);

create table public.salon_cash_reconciliations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  closure_id uuid not null,
  request_id uuid not null,
  cash_payments_cents bigint not null,
  drawer_movements_cents bigint not null,
  expected_cash_cents bigint not null,
  counted_cash_cents bigint not null,
  difference_cents bigint not null,
  note text,
  reconciled_by uuid not null references auth.users(id),
  reconciled_at timestamptz not null,
  created_at timestamptz not null,
  constraint salon_cash_reconciliations_org_closure_fk
    foreign key (organization_id, closure_id)
    references public.salon_cash_closures(organization_id, id),
  constraint salon_cash_reconciliations_closure_uniq unique (organization_id, closure_id),
  constraint salon_cash_reconciliations_request_uniq unique (organization_id, request_id),
  constraint salon_cash_reconciliations_counted_check check (counted_cash_cents >= 0),
  constraint salon_cash_reconciliations_expected_math_check
    check (expected_cash_cents = cash_payments_cents + drawer_movements_cents),
  constraint salon_cash_reconciliations_difference_math_check
    check (difference_cents = counted_cash_cents - expected_cash_cents),
  constraint salon_cash_reconciliations_note_check
    check (note is null or char_length(note) <= 500)
);

create index salon_cash_reconciliations_reconciled_by_idx
  on public.salon_cash_reconciliations(reconciled_by);

alter table public.salon_cash_reconciliations enable row level security;

create policy "salon cash roles read reconciliations"
on public.salon_cash_reconciliations for select to authenticated
using (
  salon_private.has_org_role(organization_id, array['owner','admin','manager','cashier'])
);

create policy "salon cash roles insert reconciliations"
on public.salon_cash_reconciliations for insert to authenticated
with check (
  reconciled_by = (select auth.uid())
  and salon_private.has_org_role(organization_id, array['owner','admin','manager','cashier'])
);

revoke all on table public.salon_cash_reconciliations from public, anon, authenticated;
grant select on public.salon_cash_reconciliations to authenticated;
grant insert (organization_id, closure_id, request_id, counted_cash_cents, note)
  on public.salon_cash_reconciliations to authenticated;

create function salon_private.prepare_cash_reconciliation()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_close public.salon_cash_closures;
  v_cash_payments bigint;
  v_drawer bigint;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode='28000';
  end if;
  if new.request_id is null then
    raise exception 'request_id is required' using errcode='23514';
  end if;
  if new.counted_cash_cents is null or new.counted_cash_cents < 0 then
    raise exception 'counted_cash_cents must be zero or positive' using errcode='23514';
  end if;
  if new.note is not null and char_length(btrim(new.note)) > 500 then
    raise exception 'note is too long' using errcode='23514';
  end if;

  select c.* into v_close
    from public.salon_cash_closures c
   where c.organization_id=new.organization_id and c.id=new.closure_id;
  if not found then
    raise exception 'cash closure not found in organization' using errcode='23503';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(v_close.organization_id::text),
    pg_catalog.hashtext(v_close.unit_id::text)
  );

  v_cash_payments := coalesce((v_close.method_totals_cents->>'cash')::bigint,0);
  select coalesce(sum(m.amount_delta_cents),0)::bigint into v_drawer
    from public.salon_cash_drawer_movements m
   where m.organization_id=v_close.organization_id
     and m.unit_id=v_close.unit_id
     and m.occurred_at <= v_close.period_end
     and (v_close.period_start is null or m.occurred_at > v_close.period_start);

  new.cash_payments_cents := v_cash_payments;
  new.drawer_movements_cents := v_drawer;
  new.expected_cash_cents := v_cash_payments + v_drawer;
  new.difference_cents := new.counted_cash_cents - new.expected_cash_cents;
  new.note := nullif(btrim(new.note),'');
  new.reconciled_by := auth.uid();
  new.reconciled_at := clock_timestamp();
  new.created_at := new.reconciled_at;
  return new;
end $$;
revoke all on function salon_private.prepare_cash_reconciliation() from public, anon, authenticated;

create trigger salon_cash_reconciliations_prepare
before insert on public.salon_cash_reconciliations
for each row execute function salon_private.prepare_cash_reconciliation();

create function salon_private.reject_cash_reconciliation_mutation()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $$
begin
  raise exception 'cash reconciliations are immutable' using errcode='23514';
end $$;
revoke all on function salon_private.reject_cash_reconciliation_mutation() from public, anon, authenticated;

create trigger salon_cash_reconciliations_immutable
before update or delete on public.salon_cash_reconciliations
for each row execute function salon_private.reject_cash_reconciliation_mutation();

create function public.salon_reconcile_cash_closure(
  p_organization_id uuid,
  p_closure_id uuid,
  p_counted_cash_cents bigint,
  p_request_id uuid,
  p_note text default null
)
returns table(
  reconciliation_id uuid,
  cash_payments_cents bigint,
  drawer_movements_cents bigint,
  expected_cash_cents bigint,
  counted_cash_cents bigint,
  difference_cents bigint,
  reconciled_at timestamptz,
  idempotent_replay boolean
)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_row public.salon_cash_reconciliations;
  v_replay boolean := false;
begin
  if auth.uid() is null
     or not salon_private.has_org_role(p_organization_id,array['owner','admin','manager','cashier']) then
    raise exception 'not authorized to reconcile cash closure' using errcode='42501';
  end if;
  if p_closure_id is null or p_request_id is null then
    raise exception 'closure_id and request_id are required' using errcode='23514';
  end if;
  if p_counted_cash_cents is null or p_counted_cash_cents < 0 then
    raise exception 'counted_cash_cents must be zero or positive' using errcode='23514';
  end if;
  if p_note is not null and char_length(btrim(p_note)) > 500 then
    raise exception 'note is too long' using errcode='23514';
  end if;

  select r.* into v_row
    from public.salon_cash_reconciliations r
   where r.organization_id=p_organization_id and r.request_id=p_request_id;
  if found then
    if v_row.closure_id is distinct from p_closure_id
       or v_row.counted_cash_cents is distinct from p_counted_cash_cents
       or coalesce(v_row.note,'') is distinct from coalesce(nullif(btrim(p_note),''),'') then
      raise exception 'idempotency key reused with different reconciliation payload' using errcode='23514';
    end if;
    v_replay := true;
  else
    insert into public.salon_cash_reconciliations(
      organization_id,closure_id,request_id,counted_cash_cents,note
    ) values (
      p_organization_id,p_closure_id,p_request_id,p_counted_cash_cents,p_note
    )
    on conflict (organization_id,request_id) do nothing
    returning * into v_row;

    if v_row.id is null then
      select r.* into v_row
        from public.salon_cash_reconciliations r
       where r.organization_id=p_organization_id and r.request_id=p_request_id;
      if v_row.closure_id is distinct from p_closure_id
         or v_row.counted_cash_cents is distinct from p_counted_cash_cents
         or coalesce(v_row.note,'') is distinct from coalesce(nullif(btrim(p_note),''),'') then
        raise exception 'idempotency key reused with different reconciliation payload' using errcode='23514';
      end if;
      v_replay := true;
    end if;
  end if;

  return query select
    v_row.id,
    v_row.cash_payments_cents,
    v_row.drawer_movements_cents,
    v_row.expected_cash_cents,
    v_row.counted_cash_cents,
    v_row.difference_cents,
    v_row.reconciled_at,
    v_replay;
end $$;
revoke all on function public.salon_reconcile_cash_closure(uuid,uuid,bigint,uuid,text) from public, anon, authenticated;
grant execute on function public.salon_reconcile_cash_closure(uuid,uuid,bigint,uuid,text) to authenticated;