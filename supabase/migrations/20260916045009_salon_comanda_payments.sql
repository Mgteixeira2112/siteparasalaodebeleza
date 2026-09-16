create table public.salon_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  comanda_id uuid not null,
  request_id uuid not null,
  amount_cents integer not null check (amount_cents > 0),
  method text not null check (method in ('cash','pix','debit_card','credit_card','other')),
  received_by uuid not null references auth.users(id),
  paid_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, request_id),
  foreign key (organization_id, comanda_id) references public.salon_comandas(organization_id, id)
);

create index salon_payments_org_comanda_idx on public.salon_payments(organization_id, comanda_id, paid_at);
create index salon_payments_received_by_idx on public.salon_payments(received_by);

alter table public.salon_payments enable row level security;

create policy "salon members read payments"
on public.salon_payments for select
to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon finance roles insert payments"
on public.salon_payments for insert
to authenticated
with check (
  salon_private.has_org_role(
    organization_id,
    array['owner','admin','manager','receptionist','cashier']::text[]
  )
  and received_by = (select auth.uid())
);

revoke all on table public.salon_payments from anon, authenticated;
grant select, insert on table public.salon_payments to authenticated;

create or replace function salon_private.validate_payment()
returns trigger
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_status text;
  v_total bigint;
  v_paid bigint;
  v_balance bigint;
begin
  new.method := lower(btrim(new.method));
  new.received_by := auth.uid();

  if new.received_by is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select c.status
    into v_status
    from public.salon_comandas c
   where c.organization_id = new.organization_id
     and c.id = new.comanda_id
   for update;

  if not found then
    raise exception 'comanda not found' using errcode = 'P0002';
  end if;

  if v_status <> 'open' then
    raise exception 'comanda is not open' using errcode = '23514';
  end if;

  select coalesce(sum(i.total_price_cents), 0)
    into v_total
    from public.salon_comanda_items i
   where i.organization_id = new.organization_id
     and i.comanda_id = new.comanda_id;

  select coalesce(sum(p.amount_cents), 0)
    into v_paid
    from public.salon_payments p
   where p.organization_id = new.organization_id
     and p.comanda_id = new.comanda_id;

  v_balance := v_total - v_paid;

  if v_balance <= 0 then
    raise exception 'comanda has no outstanding balance' using errcode = '23514';
  end if;

  if new.amount_cents > v_balance then
    raise exception 'payment exceeds outstanding balance' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function salon_private.validate_payment() from public, anon, authenticated;

create trigger salon_payments_validate
before insert on public.salon_payments
for each row execute function salon_private.validate_payment();

create or replace function salon_private.close_comanda_after_payment()
returns trigger
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_total bigint;
  v_paid bigint;
begin
  select coalesce(sum(i.total_price_cents), 0)
    into v_total
    from public.salon_comanda_items i
   where i.organization_id = new.organization_id
     and i.comanda_id = new.comanda_id;

  select coalesce(sum(p.amount_cents), 0)
    into v_paid
    from public.salon_payments p
   where p.organization_id = new.organization_id
     and p.comanda_id = new.comanda_id;

  if v_total > 0 and v_paid = v_total then
    update public.salon_comandas
       set status = 'paid', paid_at = new.paid_at
     where organization_id = new.organization_id
       and id = new.comanda_id
       and status = 'open';
  end if;

  return new;
end;
$$;

revoke execute on function salon_private.close_comanda_after_payment() from public, anon, authenticated;

create trigger salon_payments_close_comanda
after insert on public.salon_payments
for each row execute function salon_private.close_comanda_after_payment();

create or replace function public.salon_pay_comanda(
  p_organization_id uuid,
  p_comanda_id uuid,
  p_amount_cents integer,
  p_method text,
  p_request_id uuid
)
returns table (
  payment_id uuid,
  comanda_status text,
  total_cents bigint,
  paid_cents bigint,
  balance_cents bigint
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_payment public.salon_payments;
  v_method text := lower(btrim(p_method));
begin
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '23514';
  end if;

  select p.*
    into v_payment
    from public.salon_payments p
   where p.organization_id = p_organization_id
     and p.request_id = p_request_id;

  if found then
    if v_payment.comanda_id <> p_comanda_id
       or v_payment.amount_cents <> p_amount_cents
       or v_payment.method <> v_method then
      raise exception 'idempotency key reused with different payment payload' using errcode = '23514';
    end if;
  else
    insert into public.salon_payments(
      organization_id, comanda_id, request_id, amount_cents, method, received_by
    ) values (
      p_organization_id, p_comanda_id, p_request_id, p_amount_cents, v_method, auth.uid()
    )
    on conflict (organization_id, request_id) do nothing
    returning * into v_payment;

    if v_payment.id is null then
      select p.*
        into v_payment
        from public.salon_payments p
       where p.organization_id = p_organization_id
         and p.request_id = p_request_id;

      if v_payment.comanda_id <> p_comanda_id
         or v_payment.amount_cents <> p_amount_cents
         or v_payment.method <> v_method then
        raise exception 'idempotency key reused with different payment payload' using errcode = '23514';
      end if;
    end if;
  end if;

  return query
  select v_payment.id,
         c.status,
         coalesce((select sum(i.total_price_cents)::bigint from public.salon_comanda_items i where i.organization_id=c.organization_id and i.comanda_id=c.id),0),
         coalesce((select sum(p.amount_cents)::bigint from public.salon_payments p where p.organization_id=c.organization_id and p.comanda_id=c.id),0),
         coalesce((select sum(i.total_price_cents)::bigint from public.salon_comanda_items i where i.organization_id=c.organization_id and i.comanda_id=c.id),0)
           - coalesce((select sum(p.amount_cents)::bigint from public.salon_payments p where p.organization_id=c.organization_id and p.comanda_id=c.id),0)
    from public.salon_comandas c
   where c.organization_id = p_organization_id
     and c.id = p_comanda_id;
end;
$$;

revoke execute on function public.salon_pay_comanda(uuid, uuid, integer, text, uuid) from public, anon;
grant execute on function public.salon_pay_comanda(uuid, uuid, integer, text, uuid) to authenticated;

update public.salon_comandas c
   set status = 'paid', paid_at = coalesce(c.paid_at, now())
 where c.status = 'open'
   and 0 = coalesce((select sum(i.total_price_cents) from public.salon_comanda_items i where i.organization_id=c.organization_id and i.comanda_id=c.id),0);
