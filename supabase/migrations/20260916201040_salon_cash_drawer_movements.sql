create table public.salon_cash_drawer_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  unit_id uuid not null,
  request_id uuid not null,
  reason text not null,
  amount_delta_cents bigint not null,
  note text,
  created_by uuid not null references auth.users(id),
  occurred_at timestamptz not null,
  created_at timestamptz not null,
  constraint salon_cash_drawer_movements_org_unit_fk
    foreign key (organization_id, unit_id) references public.salon_units(organization_id, id),
  constraint salon_cash_drawer_movements_reason_check
    check (reason in ('opening_float','cash_in','cash_out')),
  constraint salon_cash_drawer_movements_amount_check
    check (
      (reason in ('opening_float','cash_in') and amount_delta_cents > 0)
      or (reason = 'cash_out' and amount_delta_cents < 0)
    ),
  constraint salon_cash_drawer_movements_note_check
    check (note is null or char_length(note) <= 500),
  constraint salon_cash_drawer_movements_request_uniq unique (organization_id, request_id)
);

create index salon_cash_drawer_movements_org_unit_time_idx
  on public.salon_cash_drawer_movements(organization_id, unit_id, occurred_at, id);
create index salon_cash_drawer_movements_created_by_idx
  on public.salon_cash_drawer_movements(created_by);

alter table public.salon_cash_drawer_movements enable row level security;

create policy "salon cash roles read drawer movements"
on public.salon_cash_drawer_movements for select to authenticated
using (
  salon_private.has_org_role(organization_id, array['owner','admin','manager','cashier'])
);

create policy "salon cash roles post drawer movements"
on public.salon_cash_drawer_movements for insert to authenticated
with check (
  created_by = (select auth.uid())
  and salon_private.has_org_role(organization_id, array['owner','admin','manager','cashier'])
);

grant select on public.salon_cash_drawer_movements to authenticated;
grant insert (organization_id, unit_id, request_id, reason, amount_delta_cents, note)
  on public.salon_cash_drawer_movements to authenticated;
revoke all on public.salon_cash_drawer_movements from anon;

create function salon_private.prepare_cash_drawer_movement()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_unit_status text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode='28000';
  end if;
  if new.request_id is null then
    raise exception 'request_id is required' using errcode='23514';
  end if;
  if new.reason is null or new.reason not in ('opening_float','cash_in','cash_out') then
    raise exception 'invalid cash drawer movement reason' using errcode='23514';
  end if;
  if (new.reason in ('opening_float','cash_in') and new.amount_delta_cents <= 0)
     or (new.reason='cash_out' and new.amount_delta_cents >= 0) then
    raise exception 'cash drawer movement sign does not match reason' using errcode='23514';
  end if;
  select u.status into v_unit_status
    from public.salon_units u
   where u.organization_id=new.organization_id and u.id=new.unit_id;
  if not found or v_unit_status <> 'active' then
    raise exception 'unit must be active and belong to organization' using errcode='23514';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(new.organization_id::text),
    pg_catalog.hashtext(new.unit_id::text)
  );

  new.note := nullif(btrim(new.note),'');
  new.created_by := auth.uid();
  new.occurred_at := clock_timestamp();
  new.created_at := new.occurred_at;
  return new;
end $$;
revoke all on function salon_private.prepare_cash_drawer_movement() from public, anon, authenticated;

create trigger salon_cash_drawer_movements_prepare
before insert on public.salon_cash_drawer_movements
for each row execute function salon_private.prepare_cash_drawer_movement();

create function salon_private.reject_cash_drawer_movement_mutation()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $$
begin
  raise exception 'cash drawer movements are append-only; post a compensating movement instead' using errcode='23514';
end $$;
revoke all on function salon_private.reject_cash_drawer_movement_mutation() from public, anon, authenticated;

create trigger salon_cash_drawer_movements_immutable
before update or delete on public.salon_cash_drawer_movements
for each row execute function salon_private.reject_cash_drawer_movement_mutation();

create function public.salon_post_cash_drawer_movement(
  p_organization_id uuid,
  p_unit_id uuid,
  p_amount_cents bigint,
  p_reason text,
  p_request_id uuid,
  p_note text default null
)
returns table(
  movement_id uuid,
  amount_delta_cents bigint,
  occurred_at timestamptz,
  idempotent_replay boolean
)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_row public.salon_cash_drawer_movements;
  v_reason text := lower(btrim(p_reason));
  v_delta bigint;
  v_replay boolean := false;
begin
  if auth.uid() is null
     or not salon_private.has_org_role(p_organization_id,array['owner','admin','manager','cashier']) then
    raise exception 'not authorized to post cash drawer movement' using errcode='42501';
  end if;
  if p_unit_id is null or p_request_id is null then
    raise exception 'unit_id and request_id are required' using errcode='23514';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount_cents must be positive' using errcode='23514';
  end if;
  if v_reason not in ('opening_float','cash_in','cash_out') then
    raise exception 'invalid cash drawer movement reason' using errcode='23514';
  end if;
  if p_note is not null and char_length(btrim(p_note)) > 500 then
    raise exception 'note is too long' using errcode='23514';
  end if;
  v_delta := case when v_reason='cash_out' then -p_amount_cents else p_amount_cents end;

  select m.* into v_row
    from public.salon_cash_drawer_movements m
   where m.organization_id=p_organization_id and m.request_id=p_request_id;
  if found then
    if v_row.unit_id is distinct from p_unit_id
       or v_row.amount_delta_cents is distinct from v_delta
       or v_row.reason is distinct from v_reason
       or coalesce(v_row.note,'') is distinct from coalesce(nullif(btrim(p_note),''),'') then
      raise exception 'idempotency key reused with different cash movement payload' using errcode='23514';
    end if;
    v_replay := true;
  else
    insert into public.salon_cash_drawer_movements(
      organization_id,unit_id,request_id,reason,amount_delta_cents,note
    ) values (
      p_organization_id,p_unit_id,p_request_id,v_reason,v_delta,p_note
    )
    on conflict (organization_id,request_id) do nothing
    returning * into v_row;
    if v_row.id is null then
      select m.* into v_row
        from public.salon_cash_drawer_movements m
       where m.organization_id=p_organization_id and m.request_id=p_request_id;
      if v_row.unit_id is distinct from p_unit_id
         or v_row.amount_delta_cents is distinct from v_delta
         or v_row.reason is distinct from v_reason
         or coalesce(v_row.note,'') is distinct from coalesce(nullif(btrim(p_note),''),'') then
        raise exception 'idempotency key reused with different cash movement payload' using errcode='23514';
      end if;
      v_replay := true;
    end if;
  end if;

  return query select v_row.id,v_row.amount_delta_cents,v_row.occurred_at,v_replay;
end $$;
revoke all on function public.salon_post_cash_drawer_movement(uuid,uuid,bigint,text,uuid,text) from public, anon, authenticated;
grant execute on function public.salon_post_cash_drawer_movement(uuid,uuid,bigint,text,uuid,text) to authenticated;