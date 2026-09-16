revoke all on table public.salon_cash_drawer_movements from public, anon, authenticated;
grant select on public.salon_cash_drawer_movements to authenticated;
grant insert (organization_id, unit_id, request_id, reason, amount_delta_cents, note)
  on public.salon_cash_drawer_movements to authenticated;