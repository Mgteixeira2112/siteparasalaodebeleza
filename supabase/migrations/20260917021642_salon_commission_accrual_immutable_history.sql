create function salon_private.reject_commission_accrual_mutation()
returns trigger language plpgsql security invoker set search_path = '' as $fn$
begin
  raise exception 'commission accrual history is immutable' using errcode = '23514';
end $fn$;
revoke all on function salon_private.reject_commission_accrual_mutation() from public, anon, authenticated;
create trigger salon_commission_accruals_immutable
  before update or delete on public.salon_commission_accruals
  for each row execute function salon_private.reject_commission_accrual_mutation();