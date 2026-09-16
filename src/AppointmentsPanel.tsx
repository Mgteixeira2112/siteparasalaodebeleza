import { FormEvent, useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

type Client = {
  id: string
  full_name: string
  phone: string | null
  email: string | null
}

type Unit = {
  id: string
  name: string
  code: string | null
}

type Professional = {
  id: string
  display_name: string
}

type Service = {
  id: string
  name: string
  duration_minutes: number
}

type ProfessionalService = {
  professional_id: string
  service_id: string
}

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

const operatorRoles = new Set(['owner', 'admin', 'manager', 'receptionist'])

const statusLabels: Record<string, string> = {
  scheduled: 'Agendado',
  confirmed: 'Confirmado',
  checked_in: 'Chegou',
  in_service: 'Em atendimento',
  completed: 'Finalizado',
  cancelled: 'Cancelado',
  no_show: 'Não compareceu',
}

function friendlyAppointmentError(message: string) {
  if (message.includes('appointment is outside professional availability')) {
    return 'Horário fora da disponibilidade do profissional.'
  }
  if (message.includes('professional is not assigned to service')) {
    return 'O profissional não está habilitado para esse serviço.'
  }
  if (message.includes('salon_appointments_professional_no_overlap')) {
    return 'O profissional já está ocupado nesse horário.'
  }
  if (message.includes('appointment conflicts with calendar block')) {
    return 'Esse horário está bloqueado.'
  }
  if (message.includes('appointment requires active client, service, professional and unit')) {
    return 'Cliente, serviço, profissional e unidade precisam estar ativos.'
  }
  return message
}

export function AppointmentsPanel({ organizationId, role }: { organizationId: string; role: string }) {
  const [clients, setClients] = useState<Client[]>([])
  const [units, setUnits] = useState<Unit[]>([])
  const [professionals, setProfessionals] = useState<Professional[]>([])
  const [services, setServices] = useState<Service[]>([])
  const [links, setLinks] = useState<ProfessionalService[]>([])
  const [appointments, setAppointments] = useState<Appointment[]>([])
  const [clientName, setClientName] = useState('')
  const [clientPhone, setClientPhone] = useState('')
  const [clientEmail, setClientEmail] = useState('')
  const [clientId, setClientId] = useState('')
  const [unitId, setUnitId] = useState('')
  const [serviceId, setServiceId] = useState('')
  const [professionalId, setProfessionalId] = useState('')
  const [startsAt, setStartsAt] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const canOperate = operatorRoles.has(role)

  async function loadAgenda() {
    setLoading(true)
    setMessage('')

    const [clientsResult, unitsResult, professionalsResult, servicesResult, linksResult, appointmentsResult] =
      await Promise.all([
        supabase
          .from('salon_clients')
          .select('id, full_name, phone, email')
          .eq('organization_id', organizationId)
          .eq('status', 'active')
          .order('full_name'),
        supabase
          .from('salon_units')
          .select('id, name, code')
          .eq('organization_id', organizationId)
          .eq('status', 'active')
          .order('name'),
        supabase
          .from('salon_professionals')
          .select('id, display_name')
          .eq('organization_id', organizationId)
          .eq('status', 'active')
          .order('display_name'),
        supabase
          .from('salon_services')
          .select('id, name, duration_minutes')
          .eq('organization_id', organizationId)
          .eq('status', 'active')
          .order('name'),
        supabase
          .from('salon_professional_services')
          .select('professional_id, service_id')
          .eq('organization_id', organizationId),
        supabase
          .from('salon_appointments')
          .select('id, client_id, unit_id, service_id, professional_id, starts_at, ends_at, status')
          .eq('organization_id', organizationId)
          .order('starts_at', { ascending: false })
          .limit(20),
      ])

    const error =
      clientsResult.error ??
      unitsResult.error ??
      professionalsResult.error ??
      servicesResult.error ??
      linksResult.error ??
      appointmentsResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextClients = (clientsResult.data ?? []) as Client[]
    const nextUnits = (unitsResult.data ?? []) as Unit[]
    const nextProfessionals = (professionalsResult.data ?? []) as Professional[]
    const nextServices = (servicesResult.data ?? []) as Service[]
    const nextLinks = (linksResult.data ?? []) as ProfessionalService[]

    setClients(nextClients)
    setUnits(nextUnits)
    setProfessionals(nextProfessionals)
    setServices(nextServices)
    setLinks(nextLinks)
    setAppointments((appointmentsResult.data ?? []) as Appointment[])

    const nextServiceId = nextServices.some((service) => service.id === serviceId)
      ? serviceId
      : nextServices[0]?.id ?? ''
    const eligibleProfessionalIds = new Set(
      nextLinks.filter((link) => link.service_id === nextServiceId).map((link) => link.professional_id),
    )
    const nextProfessionalId = eligibleProfessionalIds.has(professionalId)
      ? professionalId
      : nextProfessionals.find((professional) => eligibleProfessionalIds.has(professional.id))?.id ?? ''

    setClientId((current) => (nextClients.some((client) => client.id === current) ? current : nextClients[0]?.id ?? ''))
    setUnitId((current) => (nextUnits.some((unit) => unit.id === current) ? current : nextUnits[0]?.id ?? ''))
    setServiceId(nextServiceId)
    setProfessionalId(nextProfessionalId)
    setLoading(false)
  }

  useEffect(() => {
    void loadAgenda()
  }, [organizationId])

  const eligibleProfessionals = useMemo(() => {
    const ids = new Set(links.filter((link) => link.service_id === serviceId).map((link) => link.professional_id))
    return professionals.filter((professional) => ids.has(professional.id))
  }, [links, professionals, serviceId])

  useEffect(() => {
    if (!eligibleProfessionals.some((professional) => professional.id === professionalId)) {
      setProfessionalId(eligibleProfessionals[0]?.id ?? '')
    }
  }, [eligibleProfessionals, professionalId])

  async function createClient(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canOperate) return

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase
      .from('salon_clients')
      .insert({
        organization_id: organizationId,
        full_name: clientName.trim(),
        phone: clientPhone.trim() || null,
        email: clientEmail.trim() || null,
      })
      .select('id')
      .single()

    if (error) {
      setMessage(error.message)
    } else {
      setClientName('')
      setClientPhone('')
      setClientEmail('')
      await loadAgenda()
      if (data?.id) setClientId(data.id)
    }

    setBusy(false)
  }

  async function createAppointment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canOperate || !clientId || !unitId || !serviceId || !professionalId || !startsAt) return

    const parsedStart = new Date(startsAt)
    if (Number.isNaN(parsedStart.getTime())) {
      setMessage('Revise a data e o horário.')
      return
    }

    setBusy(true)
    setMessage('')

    const { error } = await supabase.from('salon_appointments').insert({
      organization_id: organizationId,
      unit_id: unitId,
      client_id: clientId,
      service_id: serviceId,
      professional_id: professionalId,
      starts_at: parsedStart.toISOString(),
    })

    if (error) {
      setMessage(friendlyAppointmentError(error.message))
    } else {
      setStartsAt('')
      await loadAgenda()
    }

    setBusy(false)
  }

  const clientNames = new Map(clients.map((client) => [client.id, client.full_name]))
  const unitNames = new Map(units.map((unit) => [unit.id, unit.code ? `${unit.name} · ${unit.code}` : unit.name]))
  const professionalNames = new Map(professionals.map((professional) => [professional.id, professional.display_name]))
  const serviceNames = new Map(services.map((service) => [service.id, service.name]))
  const dateTime = new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short', timeStyle: 'short' })

  return (
    <section className="auth-card compact-card">
      <div>
        <h1>Agenda</h1>
      </div>

      {canOperate && (
        <form className="auth-form" onSubmit={createClient}>
          <label>
            Novo cliente
            <input value={clientName} onChange={(event) => setClientName(event.target.value)} required />
          </label>
          <label>
            Telefone
            <input value={clientPhone} onChange={(event) => setClientPhone(event.target.value)} inputMode="tel" />
          </label>
          <label>
            E-mail
            <input type="email" value={clientEmail} onChange={(event) => setClientEmail(event.target.value)} />
          </label>
          <button className="secondary-button" type="submit" disabled={busy}>
            Adicionar cliente
          </button>
        </form>
      )}

      {canOperate && clients.length > 0 && units.length > 0 && services.length > 0 && (
        <form className="auth-form" onSubmit={createAppointment}>
          <label>
            Cliente
            <select value={clientId} onChange={(event) => setClientId(event.target.value)}>
              {clients.map((client) => (
                <option key={client.id} value={client.id}>
                  {client.full_name}
                </option>
              ))}
            </select>
          </label>

          <label>
            Serviço
            <select value={serviceId} onChange={(event) => setServiceId(event.target.value)}>
              {services.map((service) => (
                <option key={service.id} value={service.id}>
                  {service.name} · {service.duration_minutes} min
                </option>
              ))}
            </select>
          </label>

          <label>
            Profissional
            <select
              value={professionalId}
              onChange={(event) => setProfessionalId(event.target.value)}
              disabled={eligibleProfessionals.length === 0}
            >
              {eligibleProfessionals.map((professional) => (
                <option key={professional.id} value={professional.id}>
                  {professional.display_name}
                </option>
              ))}
            </select>
          </label>

          <label>
            Unidade
            <select value={unitId} onChange={(event) => setUnitId(event.target.value)}>
              {units.map((unit) => (
                <option key={unit.id} value={unit.id}>
                  {unit.code ? `${unit.name} · ${unit.code}` : unit.name}
                </option>
              ))}
            </select>
          </label>

          <label>
            Data e hora
            <input
              type="datetime-local"
              value={startsAt}
              onChange={(event) => setStartsAt(event.target.value)}
              required
            />
          </label>

          <button className="primary-button" type="submit" disabled={busy || eligibleProfessionals.length === 0}>
            Agendar
          </button>
        </form>
      )}

      {message && <p className="form-message">{message}</p>}
      {loading && <span className="loading-state">Carregando…</span>}

      {!loading && appointments.length > 0 && (
        <div className="auth-form">
          {appointments.map((appointment) => (
            <div key={appointment.id}>
              <strong>{clientNames.get(appointment.client_id)}</strong>
              <span>
                {' '}· {serviceNames.get(appointment.service_id)} · {professionalNames.get(appointment.professional_id)} ·{' '}
                {dateTime.format(new Date(appointment.starts_at))} · {unitNames.get(appointment.unit_id)} ·{' '}
                {statusLabels[appointment.status] ?? appointment.status}
              </span>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}
