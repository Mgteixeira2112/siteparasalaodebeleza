import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

type Appointment = {
  id: string
  client_id: string
  unit_id: string
  service_id: string
  professional_id: string
  starts_at: string
  ends_at: string
  status: string
}

type NamedRow = {
  id: string
  name: string
}

type Action = { label: string; status: string }

const operatorRoles = new Set(['owner', 'admin', 'manager', 'receptionist'])

const actionsByStatus: Record<string, Action[]> = {
  scheduled: [
    { label: 'Confirmar', status: 'confirmed' },
    { label: 'Registrar chegada', status: 'checked_in' },
  ],
  confirmed: [{ label: 'Registrar chegada', status: 'checked_in' }],
  checked_in: [{ label: 'Iniciar', status: 'in_service' }],
  in_service: [{ label: 'Finalizar', status: 'completed' }],
}

const statusLabels: Record<string, string> = {
  scheduled: 'Agendado',
  confirmed: 'Confirmado',
  checked_in: 'Chegou',
  in_service: 'Em atendimento',
  completed: 'Finalizado',
  cancelled: 'Cancelado',
  no_show: 'Não compareceu',
}

function dayRange() {
  const start = new Date()
  start.setHours(0, 0, 0, 0)
  const end = new Date(start)
  end.setDate(end.getDate() + 1)
  return { start: start.toISOString(), end: end.toISOString() }
}

export function TodayPanel({ organizationId }: { organizationId: string }) {
  const [appointments, setAppointments] = useState<Appointment[]>([])
  const [clients, setClients] = useState<NamedRow[]>([])
  const [professionals, setProfessionals] = useState<NamedRow[]>([])
  const [services, setServices] = useState<NamedRow[]>([])
  const [units, setUnits] = useState<NamedRow[]>([])
  const [canOperate, setCanOperate] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState('')

  async function loadToday() {
    setLoading(true)
    setMessage('')
    const { start, end } = dayRange()

    const [appointmentsResult, clientsResult, professionalsResult, servicesResult, unitsResult] = await Promise.all([
      supabase
        .from('salon_appointments')
        .select('id, client_id, unit_id, service_id, professional_id, starts_at, ends_at, status')
        .eq('organization_id', organizationId)
        .gte('starts_at', start)
        .lt('starts_at', end)
        .order('starts_at'),
      supabase.from('salon_clients').select('id, full_name').eq('organization_id', organizationId),
      supabase.from('salon_professionals').select('id, display_name').eq('organization_id', organizationId),
      supabase.from('salon_services').select('id, name').eq('organization_id', organizationId),
      supabase.from('salon_units').select('id, name').eq('organization_id', organizationId),
    ])

    const error =
      appointmentsResult.error ??
      clientsResult.error ??
      professionalsResult.error ??
      servicesResult.error ??
      unitsResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setAppointments((appointmentsResult.data ?? []) as Appointment[])
    setClients((clientsResult.data ?? []).map((row) => ({ id: row.id, name: row.full_name })))
    setProfessionals((professionalsResult.data ?? []).map((row) => ({ id: row.id, name: row.display_name })))
    setServices((servicesResult.data ?? []).map((row) => ({ id: row.id, name: row.name })))
    setUnits((unitsResult.data ?? []).map((row) => ({ id: row.id, name: row.name })))
    setLoading(false)
  }

  useEffect(() => {
    let active = true
    setCanOperate(false)
    void supabase.auth.getUser().then(async ({ data, error }) => {
      if (error || !data.user) return
      const membership = await supabase
        .from('salon_members')
        .select('role')
        .eq('organization_id', organizationId)
        .eq('user_id', data.user.id)
        .eq('status', 'active')
        .maybeSingle()
      if (active && !membership.error) setCanOperate(operatorRoles.has(membership.data?.role ?? ''))
    })
    return () => { active = false }
  }, [organizationId])

  useEffect(() => {
    void loadToday()

    const channel = supabase
      .channel(`salon-today-${organizationId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'salon_appointments',
          filter: `organization_id=eq.${organizationId}`,
        },
        () => void loadToday(),
      )
      .subscribe()

    return () => {
      void supabase.removeChannel(channel)
    }
  }, [organizationId])

  async function transition(appointment: Appointment, nextStatus: string) {
    if (!canOperate || busyId) return
    if (nextStatus === 'completed' && !window.confirm('Finalizar atendimento e gerar a comanda?')) return

    setBusyId(appointment.id)
    setMessage('')
    const { error } = await supabase.rpc('salon_transition_appointment', {
      p_organization_id: organizationId,
      p_appointment_id: appointment.id,
      p_to_status: nextStatus,
    })

    if (error) {
      setMessage(error.message)
    } else {
      await loadToday()
    }
    setBusyId(null)
  }

  const names = useMemo(
    () => ({
      clients: new Map(clients.map((item) => [item.id, item.name])),
      professionals: new Map(professionals.map((item) => [item.id, item.name])),
      services: new Map(services.map((item) => [item.id, item.name])),
      units: new Map(units.map((item) => [item.id, item.name])),
    }),
    [clients, professionals, services, units],
  )

  const activeCount = appointments.filter((appointment) =>
    ['scheduled', 'confirmed', 'checked_in', 'in_service'].includes(appointment.status),
  ).length
  const inServiceCount = appointments.filter((appointment) => appointment.status === 'in_service').length
  const completedCount = appointments.filter((appointment) => appointment.status === 'completed').length
  const time = new Intl.DateTimeFormat('pt-BR', { hour: '2-digit', minute: '2-digit' })

  return (
    <section className="auth-card compact-card">
      <div>
        <h1>Hoje</h1>
        {!loading && appointments.length > 0 && (
          <p>{activeCount} ativos · {inServiceCount} em atendimento · {completedCount} finalizados</p>
        )}
      </div>

      {message && <p className="form-message" role="alert">{message}</p>}
      {loading && <span className="loading-state">Carregando…</span>}

      {!loading && appointments.length === 0 && <span className="loading-state">Nenhum atendimento hoje.</span>}

      {!loading && appointments.length > 0 && (
        <div className="auth-form">
          {appointments.map((appointment) => (
            <div key={appointment.id}>
              <strong>{time.format(new Date(appointment.starts_at))} · {names.clients.get(appointment.client_id)}</strong>
              <span>
                {' '}· {names.services.get(appointment.service_id)} · {names.professionals.get(appointment.professional_id)} ·{' '}
                {names.units.get(appointment.unit_id)} · {statusLabels[appointment.status] ?? appointment.status}
              </span>
              {canOperate && (actionsByStatus[appointment.status] ?? []).map((action) => (
                <button
                  key={action.status}
                  className="text-button"
                  type="button"
                  disabled={busyId !== null}
                  onClick={() => void transition(appointment, action.status)}
                >
                  {action.label}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}
    </section>
  )
}
