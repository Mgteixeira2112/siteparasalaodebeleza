create table public.salon_comandas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  unit_id uuid not null,
  client_id uuid not null,
  appointment_id uuid not null,
  status text not null default 'open' check (status in ('open','paid','cancelled')),
  opened_at timestamptz not null default now(),
  paid_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, appointment_id),
  foreign key (organization_id, unit_id) references public.salon_units(organization_id, id),
  foreign key (organization_id, client_id) references public.salon_clients(organization_id, id),
  foreign key (organization_id, appointment_id) references public.salon_appointments(organization_id, id),
  check ((status = 'paid' and paid_at is not null) or (status <> 'paid' and paid_at is null))
);

create table public.salon_comanda_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  comanda_id uuid not null,
  appointment_id uuid not null,
  service_id uuid not null,
  description text not null check (length(btrim(description)) > 0),
  quantity integer not null default 1 check (quantity > 0),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  total_price_cents integer generated always as (quantity * unit_price_cents) stored,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, appointment_id),
  foreign key (organization_id, comanda_id) references public.salon_comandas(organization_id, id),
  foreign key (organization_id, appointment_id) references public.salon_appointments(organization_id, id),
  foreign key (organization_id, service_id) references public.salon_services(organization_id, id)
);

create index salon_comandas_org_status_idx on public.salon_comandas(organization_id, status, opened_at desc);
create index salon_comandas_org_unit_fk_idx on public.salon_comandas(organization_id, unit_id);
create index salon_comandas_org_client_fk_idx on public.salon_comandas(organization_id, client_id);
create index salon_comandas_created_by_idx on public.salon_comandas(created_by);
create index salon_comanda_items_org_comanda_fk_idx on public.salon_comanda_items(organization_id, comanda_id);
create index salon_comanda_items_org_service_fk_idx on public.salon_comanda_items(organization_id, service_id);

alter table public.salon_comandas enable row level security;
alter table public.salon_comanda_items enable row level security;

create policy "salon members read comandas"
on public.salon_comandas for select
to authenticated
using (salon_private.is_active_member(organization_id));

create policy "salon members read comanda items"
on public.salon_comanda_items for select
to authenticated
using (salon_private.is_active_member(organization_id));

revoke all on table public.salon_comandas from anon, authenticated;
revoke all on table public.salon_comanda_items from anon, authenticated;
grant select on table public.salon_comandas to authenticated;
grant select on table public.salon_comanda_items to authenticated;

create trigger salon_comandas_touch_updated_at
before update on public.salon_comandas
for each row execute function salon_private.touch_updated_at();

create or replace function salon_private.create_comanda_on_completion()
returns trigger
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_comanda_id uuid;
  v_service_name text;
begin
  if new.status = 'completed' and old.status is distinct from new.status then
    select s.name into v_service_name
      from public.salon_services s
     where s.organization_id = new.organization_id
       and s.id = new.service_id;

    insert into public.salon_comandas(
      organization_id, unit_id, client_id, appointment_id, status, created_by
    ) values (
      new.organization_id, new.unit_id, new.client_id, new.id, 'open', auth.uid()
    )
    on conflict (organization_id, appointment_id) do nothing
    returning id into v_comanda_id;

    if v_comanda_id is null then
      select c.id into v_comanda_id
        from public.salon_comandas c
       where c.organization_id = new.organization_id
         and c.appointment_id = new.id;
    end if;

    insert into public.salon_comanda_items(
      organization_id, comanda_id, appointment_id, service_id,
      description, quantity, unit_price_cents
    ) values (
      new.organization_id, v_comanda_id, new.id, new.service_id,
      v_service_name, 1, new.service_price_cents
    )
    on conflict (organization_id, appointment_id) do nothing;
  end if;

  return new;
end;
$$;

revoke execute on function salon_private.create_comanda_on_completion() from public, anon, authenticated;

drop trigger if exists salon_appointments_create_comanda on public.salon_appointments;
create trigger salon_appointments_create_comanda
after update of status on public.salon_appointments
for each row
execute function salon_private.create_comanda_on_completion();

insert into public.salon_comandas(
  organization_id, unit_id, client_id, appointment_id, status, created_by, opened_at
)
select a.organization_id, a.unit_id, a.client_id, a.id, 'open', a.created_by, coalesce(a.updated_at, a.created_at)
from public.salon_appointments a
where a.status = 'completed'
on conflict (organization_id, appointment_id) do nothing;

insert into public.salon_comanda_items(
  organization_id, comanda_id, appointment_id, service_id,
  description, quantity, unit_price_cents
)
select a.organization_id, c.id, a.id, a.service_id,
       s.name, 1, a.service_price_cents
from public.salon_appointments a
join public.salon_comandas c
  on c.organization_id = a.organization_id and c.appointment_id = a.id
join public.salon_services s
  on s.organization_id = a.organization_id and s.id = a.service_id
where a.status = 'completed'
on conflict (organization_id, appointment_id) do nothing;
