create table public.salon_commission_payouts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.salon_organizations(id),
  professional_id uuid not null,
  request_id uuid not null,
  paid_through timestamptz not null,
  method text not null check (method in ('pix','bank_transfer')),
  payment_reference text not null check (length(btrim(payment_reference)) between 1 and 160),
  note text check (note is null or length(note) <= 500),
  total_cents bigint not null check (total_cents > 0),
  line_count integer not null check (line_count > 0),
  paid_by uuid not null references auth.users(id),
  paid_at timestamptz not null,
  constraint salon_commission_payouts_org_id_key unique (organization_id,id),
  constraint salon_commission_payouts_request_key unique (organization_id,request_id),
  constraint salon_commission_payouts_professional_fkey foreign key (organization_id,professional_id)
    references public.salon_professionals(organization_id,id),
  constraint salon_commission_payouts_cutoff_check check (paid_through <= paid_at)
);
create index salon_commission_payouts_professional_idx on public.salon_commission_payouts (organization_id,professional_id,paid_at);
create index salon_commission_payouts_paid_by_idx on public.salon_commission_payouts (paid_by);

create table public.salon_commission_payout_lines (
  organization_id uuid not null,
  appointment_id uuid not null,
  payout_id uuid not null,
  commission_cents bigint not null check (commission_cents > 0),
  constraint salon_commission_payout_lines_pkey primary key (organization_id,appointment_id),
  constraint salon_commission_payout_lines_accrual_fkey foreign key (organization_id,appointment_id)
    references public.salon_commission_accruals(organization_id,appointment_id),
  constraint salon_commission_payout_lines_payout_fkey foreign key (organization_id,payout_id)
    references public.salon_commission_payouts(organization_id,id)
);
create index salon_commission_payout_lines_payout_idx on public.salon_commission_payout_lines (organization_id,payout_id);

alter table public.salon_commission_payouts enable row level security;
alter table public.salon_commission_payout_lines enable row level security;
create policy "salon managers and own professional read commission payouts" on public.salon_commission_payouts
 for select to authenticated using (
   salon_private.has_org_role(organization_id,array['owner','admin','manager'])
   or exists (
     select 1 from public.salon_professionals p
     join public.salon_members m on m.organization_id=p.organization_id and m.id=p.member_id
     where p.organization_id=salon_commission_payouts.organization_id
       and p.id=salon_commission_payouts.professional_id
       and m.user_id=(select auth.uid()) and m.status='active'
   )
 );
create policy "salon managers record commission payouts" on public.salon_commission_payouts
 for insert to authenticated with check (salon_private.has_org_role(organization_id,array['owner','admin','manager']));
create policy "salon payout lines follow payout access" on public.salon_commission_payout_lines
 for select to authenticated using (
   exists (select 1 from public.salon_commission_payouts p
      where p.organization_id=salon_commission_payout_lines.organization_id
        and p.id=salon_commission_payout_lines.payout_id)
 );
revoke all on public.salon_commission_payouts from public,anon,authenticated;
revoke all on public.salon_commission_payout_lines from public,anon,authenticated;
grant select on public.salon_commission_payouts to authenticated;
grant insert (organization_id,professional_id,request_id,paid_through,method,payment_reference,note)
  on public.salon_commission_payouts to authenticated;
grant select on public.salon_commission_payout_lines to authenticated;

create function salon_private.prepare_commission_payout()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_sum bigint; v_count bigint;
begin
  if auth.uid() is null or not salon_private.has_org_role(new.organization_id,array['owner','admin','manager']) then
    raise exception 'not authorized to record commission payout' using errcode='42501';
  end if;
  if new.organization_id is null or new.professional_id is null or new.request_id is null or new.paid_through is null then
    raise exception 'organization, professional, request and cutoff are required' using errcode='23514';
  end if;
  if new.paid_through > clock_timestamp() then
    raise exception 'commission payout cutoff cannot be in future' using errcode='23514';
  end if;
  new.method := lower(btrim(new.method));
  if new.method is null or new.method not in ('pix','bank_transfer') then
    raise exception 'commission payout method must be pix or bank_transfer' using errcode='23514';
  end if;
  new.payment_reference := nullif(btrim(new.payment_reference),'');
  if new.payment_reference is null or length(new.payment_reference) > 160 then
    raise exception 'external payment reference is required (max 160 characters)' using errcode='23514';
  end if;
  new.note := nullif(btrim(new.note),'');
  if new.note is not null and length(new.note)>500 then
    raise exception 'note too long' using errcode='23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('salon_commission_payout:'||new.organization_id::text||':'||new.professional_id::text,0));
  select coalesce(sum(a.commission_cents),0),count(*) into v_sum,v_count
    from public.salon_commission_accruals a
    where a.organization_id=new.organization_id and a.professional_id=new.professional_id
      and a.completed_at <= new.paid_through and a.commission_cents>0
      and not exists (select 1 from public.salon_commission_payout_lines l
                      where l.organization_id=a.organization_id and l.appointment_id=a.appointment_id);
  if v_count=0 or v_sum<=0 then
    raise exception 'no unpaid positive commissions for professional and cutoff' using errcode='23514';
  end if;
  if v_count>2147483647 then raise exception 'commission payout too many lines' using errcode='22003'; end if;
  new.total_cents:=v_sum;
  new.line_count:=v_count::integer;
  new.paid_by:=auth.uid();
  new.paid_at:=clock_timestamp();
  return new;
end $fn$;
revoke all on function salon_private.prepare_commission_payout() from public,anon,authenticated;
create trigger salon_commission_payouts_prepare before insert on public.salon_commission_payouts
 for each row execute function salon_private.prepare_commission_payout();

create function salon_private.post_commission_payout_lines()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_inserted bigint; v_total bigint;
begin
  insert into public.salon_commission_payout_lines (organization_id,appointment_id,payout_id,commission_cents)
  select a.organization_id,a.appointment_id,new.id,a.commission_cents
  from public.salon_commission_accruals a
  where a.organization_id=new.organization_id and a.professional_id=new.professional_id
    and a.completed_at <= new.paid_through and a.commission_cents>0
    and not exists (select 1 from public.salon_commission_payout_lines l
                    where l.organization_id=a.organization_id and l.appointment_id=a.appointment_id)
  order by a.appointment_id;
  get diagnostics v_inserted=row_count;
  select coalesce(sum(l.commission_cents),0) into v_total from public.salon_commission_payout_lines l
    where l.organization_id=new.organization_id and l.payout_id=new.id;
  if v_inserted <> new.line_count or v_total <> new.total_cents then
    raise exception 'commission payout snapshot changed during settlement' using errcode='23514';
  end if;
  return new;
end $fn$;
revoke all on function salon_private.post_commission_payout_lines() from public,anon,authenticated;
create trigger salon_commission_payouts_post_lines after insert on public.salon_commission_payouts
 for each row execute function salon_private.post_commission_payout_lines();

create function salon_private.reject_commission_payout_mutation()
returns trigger language plpgsql set search_path='' as $fn$
begin raise exception 'commission payout history is immutable' using errcode='23514'; end $fn$;
revoke all on function salon_private.reject_commission_payout_mutation() from public,anon,authenticated;
create trigger salon_commission_payouts_immutable before update or delete on public.salon_commission_payouts
 for each row execute function salon_private.reject_commission_payout_mutation();
create trigger salon_commission_payout_lines_immutable before update or delete on public.salon_commission_payout_lines
 for each row execute function salon_private.reject_commission_payout_mutation();

create function public.salon_record_commission_payout(
  p_organization_id uuid,p_professional_id uuid,p_paid_through timestamptz,
  p_method text,p_payment_reference text,p_request_id uuid,p_note text default null
)
returns table(payout_id uuid,total_cents bigint,line_count integer,paid_at timestamptz,idempotent_replay boolean)
language plpgsql security invoker set search_path='' as $fn$
declare v_row public.salon_commission_payouts; v_method text:=lower(btrim(p_method));
  v_reference text:=nullif(btrim(p_payment_reference),''); v_note text:=nullif(btrim(p_note),''); v_replay boolean:=false;
begin
  if auth.uid() is null or not salon_private.has_org_role(p_organization_id,array['owner','admin','manager']) then
    raise exception 'not authorized to record commission payout' using errcode='42501';
  end if;
  if p_professional_id is null or p_request_id is null or p_paid_through is null then
    raise exception 'professional, request and cutoff are required' using errcode='23514';
  end if;
  if v_method is null or v_method not in ('pix','bank_transfer') or v_reference is null or length(v_reference)>160
     or (v_note is not null and length(v_note)>500) then
    raise exception 'invalid commission payout method/reference/note' using errcode='23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('salon_commission_payout:'||p_organization_id::text||':'||p_professional_id::text,0));
  select p.* into v_row from public.salon_commission_payouts p
   where p.organization_id=p_organization_id and p.request_id=p_request_id;
  if found then
    if v_row.professional_id is distinct from p_professional_id
       or v_row.paid_through is distinct from p_paid_through
       or v_row.method is distinct from v_method
       or v_row.payment_reference is distinct from v_reference
       or v_row.note is distinct from v_note then
      raise exception 'idempotency key reused with different payout payload' using errcode='23514';
    end if;
    v_replay:=true;
  else
    insert into public.salon_commission_payouts
      (organization_id,professional_id,paid_through,method,payment_reference,request_id,note)
    values (p_organization_id,p_professional_id,p_paid_through,v_method,v_reference,p_request_id,v_note)
    on conflict (organization_id,request_id) do nothing
    returning * into v_row;
    if v_row.id is null then
      select p.* into v_row from public.salon_commission_payouts p
       where p.organization_id=p_organization_id and p.request_id=p_request_id;
      if v_row.id is null or v_row.professional_id is distinct from p_professional_id
         or v_row.paid_through is distinct from p_paid_through or v_row.method is distinct from v_method
         or v_row.payment_reference is distinct from v_reference or v_row.note is distinct from v_note then
        raise exception 'idempotency key reused with different payout payload' using errcode='23514';
      end if;
      v_replay:=true;
    end if;
  end if;
  return query select v_row.id,v_row.total_cents,v_row.line_count,v_row.paid_at,v_replay;
end $fn$;
revoke all on function public.salon_record_commission_payout(uuid,uuid,timestamptz,text,text,uuid,text) from public,anon,authenticated;
grant execute on function public.salon_record_commission_payout(uuid,uuid,timestamptz,text,text,uuid,text) to authenticated;

create view public.salon_commission_positions with (security_invoker=true) as
select a.organization_id,a.professional_id,
  count(*)::bigint as completed_count,
  coalesce(sum(a.commission_cents),0)::bigint as accrued_cents,
  coalesce(sum(l.commission_cents),0)::bigint as paid_cents,
  (coalesce(sum(a.commission_cents),0)-coalesce(sum(l.commission_cents),0))::bigint as outstanding_cents
from public.salon_commission_accruals a
left join public.salon_commission_payout_lines l on l.organization_id=a.organization_id and l.appointment_id=a.appointment_id
group by a.organization_id,a.professional_id;
revoke all on public.salon_commission_positions from public,anon,authenticated;
grant select on public.salon_commission_positions to authenticated;