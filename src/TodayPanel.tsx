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
          <p>{activeCount} em andamento · {inServiceCount} em atendimento · {completedCount} finalizados</p>
        )}
      </div>

      {message && <p className="form-message">{message}</p>}
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
            </div>
          ))}
        </div>
      )}
    </section>
  )
}
