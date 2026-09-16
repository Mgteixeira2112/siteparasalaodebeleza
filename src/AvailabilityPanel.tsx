import { FormEvent, useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { AppointmentsPanel } from './AppointmentsPanel'

type Professional = {
  id: string
  display_name: string
}

type Unit = {
  id: string
  name: string
  code: string | null
}

type Availability = {
  id: string
  professional_id: string
  unit_id: string
  weekday: number
  starts_at: string
  ends_at: string
}

const managerRoles = new Set(['owner', 'admin', 'manager'])

const weekdayLabels = [
  'Domingo',
  'Segunda-feira',
  'Terça-feira',
  'Quarta-feira',
  'Quinta-feira',
  'Sexta-feira',
  'Sábado',
]

export function AvailabilityPanel({ organizationId, role }: { organizationId: string; role: string }) {
  const [professionals, setProfessionals] = useState<Professional[]>([])
  const [units, setUnits] = useState<Unit[]>([])
  const [availability, setAvailability] = useState<Availability[]>([])
  const [professionalId, setProfessionalId] = useState('')
  const [unitId, setUnitId] = useState('')
  const [weekday, setWeekday] = useState('1')
  const [startsAt, setStartsAt] = useState('09:00')
  const [endsAt, setEndsAt] = useState('18:00')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const canManage = managerRoles.has(role)

  async function loadAvailability() {
    setLoading(true)
    setMessage('')

    const [professionalsResult, unitsResult, availabilityResult] = await Promise.all([
      supabase
        .from('salon_professionals')
        .select('id, display_name')
        .eq('organization_id', organizationId)
        .eq('status', 'active')
        .order('display_name'),
      supabase
        .from('salon_units')
        .select('id, name, code')
        .eq('organization_id', organizationId)
        .eq('status', 'active')
        .order('name'),
      supabase
        .from('salon_professional_availability')
        .select('id, professional_id, unit_id, weekday, starts_at, ends_at')
        .eq('organization_id', organizationId)
        .eq('status', 'active')
        .order('weekday')
        .order('starts_at'),
    ])

    const error = professionalsResult.error ?? unitsResult.error ?? availabilityResult.error
    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextProfessionals = (professionalsResult.data ?? []) as Professional[]
    const nextUnits = (unitsResult.data ?? []) as Unit[]

    setProfessionals(nextProfessionals)
    setUnits(nextUnits)
    setAvailability((availabilityResult.data ?? []) as Availability[])
    setProfessionalId((current) =>
      nextProfessionals.some((professional) => professional.id === current)
        ? current
        : nextProfessionals[0]?.id ?? '',
    )
    setUnitId((current) => (nextUnits.some((unit) => unit.id === current) ? current : nextUnits[0]?.id ?? ''))
    setLoading(false)
  }

  useEffect(() => {
    void loadAvailability()
  }, [organizationId])

  async function createAvailability(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage || !professionalId || !unitId) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.from('salon_professional_availability').insert({
      organization_id: organizationId,
      professional_id: professionalId,
      unit_id: unitId,
      weekday: Number(weekday),
      starts_at: `${startsAt}:00`,
      ends_at: `${endsAt}:00`,
    })

    if (error) {
      setMessage(error.message)
    } else {
      await loadAvailability()
    }

    setBusy(false)
  }

  async function removeAvailability(id: string) {
    if (!canManage) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase
      .from('salon_professional_availability')
      .delete()
      .eq('organization_id', organizationId)
      .eq('id', id)

    if (error) {
      setMessage(error.message)
    } else {
      await loadAvailability()
    }

    setBusy(false)
  }

  const professionalNames = new Map(professionals.map((professional) => [professional.id, professional.display_name]))
  const unitNames = new Map(units.map((unit) => [unit.id, unit.code ? `${unit.name} · ${unit.code}` : unit.name]))

  return (
    <>
      <section className="auth-card compact-card">
        <div>
          <h1>Disponibilidade</h1>
        </div>

        {canManage && professionals.length > 0 && units.length > 0 && (
          <form className="auth-form" onSubmit={createAvailability}>
            <label>
              Profissional
              <select value={professionalId} onChange={(event) => setProfessionalId(event.target.value)}>
                {professionals.map((professional) => (
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
              Dia
              <select value={weekday} onChange={(event) => setWeekday(event.target.value)}>
                {weekdayLabels.map((label, index) => (
                  <option key={label} value={index}>
                    {label}
                  </option>
                ))}
              </select>
            </label>

            <label>
              Início
              <input type="time" value={startsAt} onChange={(event) => setStartsAt(event.target.value)} required />
            </label>

            <label>
              Fim
              <input type="time" value={endsAt} onChange={(event) => setEndsAt(event.target.value)} required />
            </label>

            <button className="primary-button" type="submit" disabled={busy}>
              Adicionar horário
            </button>
          </form>
        )}

        {message && <p className="form-message">{message}</p>}
        {loading && <span className="loading-state">Carregando…</span>}

        {!loading && availability.length > 0 && (
          <div className="auth-form">
            {availability.map((item) => (
              <div key={item.id}>
                <strong>{professionalNames.get(item.professional_id)}</strong>
                <span>
                  {' '}· {weekdayLabels[item.weekday]} · {item.starts_at.slice(0, 5)}–{item.ends_at.slice(0, 5)} ·{' '}
                  {unitNames.get(item.unit_id)}
                </span>
                {canManage && (
                  <button className="text-button" type="button" disabled={busy} onClick={() => void removeAvailability(item.id)}>
                    Remover
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </section>

      <AppointmentsPanel organizationId={organizationId} role={role} />
    </>
  )
}
