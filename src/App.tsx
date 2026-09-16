import { FormEvent, useEffect, useMemo, useState } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase } from './lib/supabase'

type Membership = {
  organization_id: string
  role: string
  status: string
  created_at: string
}

type Organization = {
  id: string
  name: string
}

type Unit = {
  id: string
  name: string
  code: string | null
  status: string
}

type Professional = {
  id: string
  display_name: string
  status: string
}

type Service = {
  id: string
  name: string
  duration_minutes: number
  base_price_cents: number
  status: string
}

type ProfessionalService = {
  professional_id: string
  service_id: string
}

const roleLabels: Record<string, string> = {
  owner: 'Proprietário',
  admin: 'Administrador',
  manager: 'Gerente',
  receptionist: 'Recepção',
  professional: 'Profissional',
  cashier: 'Caixa',
}

const managerRoles = new Set(['owner', 'admin', 'manager'])

function AuthScreen() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  async function handleSignIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true)
    setMessage('')

    const { error } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    })

    if (error) setMessage(error.message)
    setBusy(false)
  }

  async function handleSignUp() {
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
    })

    if (error) {
      setMessage(error.message)
    } else if (!data.session) {
      setMessage('Confirme seu e-mail para entrar.')
    }

    setBusy(false)
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="brand-mark">S</div>
        <div>
          <h1>Sistema de Salão</h1>
          <p>Entre para continuar.</p>
        </div>

        <form className="auth-form" onSubmit={handleSignIn}>
          <label>
            E-mail
            <input
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              autoComplete="email"
              required
            />
          </label>

          <label>
            Senha
            <input
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              autoComplete="current-password"
              minLength={6}
              required
            />
          </label>

          {message && <p className="form-message">{message}</p>}

          <button className="primary-button" type="submit" disabled={busy}>
            Entrar
          </button>
          <button className="secondary-button" type="button" onClick={handleSignUp} disabled={busy}>
            Criar conta
          </button>
        </form>
      </section>
    </main>
  )
}

function UnitsPanel({ organizationId, role }: { organizationId: string; role: string }) {
  const [units, setUnits] = useState<Unit[]>([])
  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const canManage = managerRoles.has(role)

  async function loadUnits() {
    setLoading(true)
    setMessage('')

    const { data, error } = await supabase
      .from('salon_units')
      .select('id, name, code, status')
      .eq('organization_id', organizationId)
      .eq('status', 'active')
      .order('name')

    if (error) {
      setMessage(error.message)
    } else {
      setUnits((data ?? []) as Unit[])
    }

    setLoading(false)
  }

  useEffect(() => {
    void loadUnits()
  }, [organizationId])

  async function createUnit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage) return

    setBusy(true)
    setMessage('')

    const cleanCode = code.trim()
    const { error } = await supabase.from('salon_units').insert({
      organization_id: organizationId,
      name: name.trim(),
      code: cleanCode || null,
    })

    if (error) {
      setMessage(error.message)
    } else {
      setName('')
      setCode('')
      await loadUnits()
    }

    setBusy(false)
  }

  return (
    <section className="auth-card compact-card">
      <div>
        <h1>Unidades</h1>
      </div>

      {canManage && (
        <form className="auth-form" onSubmit={createUnit}>
          <label>
            Nome
            <input value={name} onChange={(event) => setName(event.target.value)} required />
          </label>
          <label>
            Código
            <input value={code} onChange={(event) => setCode(event.target.value)} />
          </label>
          {message && <p className="form-message">{message}</p>}
          <button className="primary-button" type="submit" disabled={busy}>
            Adicionar unidade
          </button>
        </form>
      )}

      {!canManage && message && <p className="form-message">{message}</p>}

      {!loading && units.length > 0 && (
        <div>
          {units.map((unit) => (
            <div key={unit.id}>
              <strong>{unit.name}</strong>
              {unit.code && <span> · {unit.code}</span>}
            </div>
          ))}
        </div>
      )}

      {loading && <span className="loading-state">Carregando…</span>}
    </section>
  )
}

function CatalogPanel({ organizationId, role }: { organizationId: string; role: string }) {
  const [professionals, setProfessionals] = useState<Professional[]>([])
  const [services, setServices] = useState<Service[]>([])
  const [links, setLinks] = useState<ProfessionalService[]>([])
  const [professionalName, setProfessionalName] = useState('')
  const [serviceName, setServiceName] = useState('')
  const [durationMinutes, setDurationMinutes] = useState('')
  const [basePrice, setBasePrice] = useState('')
  const [selectedProfessionalId, setSelectedProfessionalId] = useState('')
  const [selectedServiceId, setSelectedServiceId] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const canManage = managerRoles.has(role)

  async function loadCatalog() {
    setLoading(true)
    setMessage('')

    const [professionalsResult, servicesResult, linksResult] = await Promise.all([
      supabase
        .from('salon_professionals')
        .select('id, display_name, status')
        .eq('organization_id', organizationId)
        .eq('status', 'active')
        .order('display_name'),
      supabase
        .from('salon_services')
        .select('id, name, duration_minutes, base_price_cents, status')
        .eq('organization_id', organizationId)
        .eq('status', 'active')
        .order('name'),
      supabase
        .from('salon_professional_services')
        .select('professional_id, service_id')
        .eq('organization_id', organizationId),
    ])

    const error = professionalsResult.error ?? servicesResult.error ?? linksResult.error
    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextProfessionals = (professionalsResult.data ?? []) as Professional[]
    const nextServices = (servicesResult.data ?? []) as Service[]
    const nextLinks = (linksResult.data ?? []) as ProfessionalService[]

    setProfessionals(nextProfessionals)
    setServices(nextServices)
    setLinks(nextLinks)
    setSelectedProfessionalId((current) =>
      nextProfessionals.some((professional) => professional.id === current)
        ? current
        : nextProfessionals[0]?.id ?? '',
    )
    setSelectedServiceId((current) =>
      nextServices.some((service) => service.id === current) ? current : nextServices[0]?.id ?? '',
    )
    setLoading(false)
  }

  useEffect(() => {
    void loadCatalog()
  }, [organizationId])

  async function createProfessional(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.from('salon_professionals').insert({
      organization_id: organizationId,
      display_name: professionalName.trim(),
    })

    if (error) {
      setMessage(error.message)
    } else {
      setProfessionalName('')
      await loadCatalog()
    }

    setBusy(false)
  }

  async function createService(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage) return

    const duration = Number(durationMinutes)
    const priceCents = Math.round(Number(basePrice) * 100)
    if (!Number.isInteger(duration) || duration <= 0 || !Number.isFinite(priceCents) || priceCents < 0) {
      setMessage('Revise duração e preço.')
      return
    }

    setBusy(true)
    setMessage('')

    const { error } = await supabase.from('salon_services').insert({
      organization_id: organizationId,
      name: serviceName.trim(),
      duration_minutes: duration,
      base_price_cents: priceCents,
    })

    if (error) {
      setMessage(error.message)
    } else {
      setServiceName('')
      setDurationMinutes('')
      setBasePrice('')
      await loadCatalog()
    }

    setBusy(false)
  }

  const selectedLinkExists = links.some(
    (link) => link.professional_id === selectedProfessionalId && link.service_id === selectedServiceId,
  )

  async function linkProfessionalService(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!canManage || !selectedProfessionalId || !selectedServiceId || selectedLinkExists) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.from('salon_professional_services').insert({
      organization_id: organizationId,
      professional_id: selectedProfessionalId,
      service_id: selectedServiceId,
    })

    if (error) {
      setMessage(error.message)
    } else {
      await loadCatalog()
    }

    setBusy(false)
  }

  const professionalNames = new Map(professionals.map((professional) => [professional.id, professional.display_name]))
  const serviceNames = new Map(services.map((service) => [service.id, service.name]))
  const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

  return (
    <section className="auth-card compact-card">
      <div>
        <h1>Equipe e serviços</h1>
      </div>

      {canManage && (
        <>
          <form className="auth-form" onSubmit={createProfessional}>
            <label>
              Profissional
              <input
                value={professionalName}
                onChange={(event) => setProfessionalName(event.target.value)}
                required
              />
            </label>
            <button className="primary-button" type="submit" disabled={busy}>
              Adicionar profissional
            </button>
          </form>

          <form className="auth-form" onSubmit={createService}>
            <label>
              Serviço
              <input value={serviceName} onChange={(event) => setServiceName(event.target.value)} required />
            </label>
            <label>
              Duração (min)
              <input
                type="number"
                min="1"
                step="1"
                value={durationMinutes}
                onChange={(event) => setDurationMinutes(event.target.value)}
                required
              />
            </label>
            <label>
              Preço base (R$)
              <input
                type="number"
                min="0"
                step="0.01"
                value={basePrice}
                onChange={(event) => setBasePrice(event.target.value)}
                required
              />
            </label>
            <button className="primary-button" type="submit" disabled={busy}>
              Adicionar serviço
            </button>
          </form>

          {professionals.length > 0 && services.length > 0 && (
            <form className="auth-form" onSubmit={linkProfessionalService}>
              <label>
                Profissional
                <select
                  value={selectedProfessionalId}
                  onChange={(event) => setSelectedProfessionalId(event.target.value)}
                >
                  {professionals.map((professional) => (
                    <option key={professional.id} value={professional.id}>
                      {professional.display_name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Serviço habilitado
                <select value={selectedServiceId} onChange={(event) => setSelectedServiceId(event.target.value)}>
                  {services.map((service) => (
                    <option key={service.id} value={service.id}>
                      {service.name}
                    </option>
                  ))}
                </select>
              </label>
              <button className="secondary-button" type="submit" disabled={busy || selectedLinkExists}>
                {selectedLinkExists ? 'Serviço habilitado' : 'Habilitar serviço'}
              </button>
            </form>
          )}
        </>
      )}

      {message && <p className="form-message">{message}</p>}
      {loading && <span className="loading-state">Carregando…</span>}

      {!loading && professionals.length > 0 && (
        <div>
          {professionals.map((professional) => (
            <div key={professional.id}>
              <strong>{professional.display_name}</strong>
            </div>
          ))}
        </div>
      )}

      {!loading && services.length > 0 && (
        <div>
          {services.map((service) => (
            <div key={service.id}>
              <strong>{service.name}</strong>
              <span> · {service.duration_minutes} min · {money.format(service.base_price_cents / 100)}</span>
            </div>
          ))}
        </div>
      )}

      {!loading && links.length > 0 && (
        <div>
          {links.map((link) => (
            <div key={`${link.professional_id}:${link.service_id}`}>
              <span>{professionalNames.get(link.professional_id)} · {serviceNames.get(link.service_id)}</span>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}

function SalonGate({ user }: { user: User }) {
  const [memberships, setMemberships] = useState<Membership[]>([])
  const [organizations, setOrganizations] = useState<Organization[]>([])
  const [selectedOrganizationId, setSelectedOrganizationId] = useState('')
  const [salonName, setSalonName] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadContext() {
    setLoading(true)
    setMessage('')

    const { data: membershipRows, error: membershipError } = await supabase
      .from('salon_members')
      .select('organization_id, role, status, created_at')
      .eq('user_id', user.id)
      .eq('status', 'active')
      .order('created_at', { ascending: true })

    if (membershipError) {
      setMessage(membershipError.message)
      setLoading(false)
      return
    }

    const nextMemberships = (membershipRows ?? []) as Membership[]
    setMemberships(nextMemberships)

    if (nextMemberships.length === 0) {
      setOrganizations([])
      setSelectedOrganizationId('')
      setLoading(false)
      return
    }

    const organizationIds = nextMemberships.map((membership) => membership.organization_id)
    const { data: organizationRows, error: organizationError } = await supabase
      .from('salon_organizations')
      .select('id, name')
      .in('id', organizationIds)
      .eq('status', 'active')

    if (organizationError) {
      setMessage(organizationError.message)
      setLoading(false)
      return
    }

    const nextOrganizations = (organizationRows ?? []) as Organization[]
    setOrganizations(nextOrganizations)
    setSelectedOrganizationId((current) =>
      current && organizationIds.includes(current) ? current : organizationIds[0],
    )
    setLoading(false)
  }

  useEffect(() => {
    void loadContext()
  }, [user.id])

  async function createSalon(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true)
    setMessage('')

    const { error } = await supabase.from('salon_organizations').insert({
      name: salonName.trim(),
      created_by: user.id,
    })

    if (error) {
      setMessage(error.message)
    } else {
      setSalonName('')
      await loadContext()
    }

    setBusy(false)
  }

  const selectedOrganization = useMemo(
    () => organizations.find((organization) => organization.id === selectedOrganizationId),
    [organizations, selectedOrganizationId],
  )

  const selectedMembership = useMemo(
    () => memberships.find((membership) => membership.organization_id === selectedOrganizationId),
    [memberships, selectedOrganizationId],
  )

  if (loading) {
    return <main className="app-shell loading-state">Carregando…</main>
  }

  if (memberships.length === 0) {
    return (
      <main className="auth-shell">
        <section className="auth-card compact-card">
          <div>
            <h1>Seu salão</h1>
            <p>Crie a organização para começar.</p>
          </div>

          <form className="auth-form" onSubmit={createSalon}>
            <label>
              Nome do salão
              <input
                value={salonName}
                onChange={(event) => setSalonName(event.target.value)}
                autoFocus
                required
              />
            </label>
            {message && <p className="form-message">{message}</p>}
            <button className="primary-button" type="submit" disabled={busy}>
              Criar salão
            </button>
          </form>

          <button className="text-button" type="button" onClick={() => void supabase.auth.signOut()}>
            Sair
          </button>
        </section>
      </main>
    )
  }

  return (
    <div className="workspace-shell">
      <header className="topbar">
        <div className="topbar-brand">
          <span className="brand-mark small-mark">S</span>
          <div>
            <strong>{selectedOrganization?.name ?? 'Sistema de Salão'}</strong>
            <span>{roleLabels[selectedMembership?.role ?? ''] ?? selectedMembership?.role}</span>
          </div>
        </div>

        <div className="topbar-actions">
          {organizations.length > 1 && (
            <select
              value={selectedOrganizationId}
              onChange={(event) => setSelectedOrganizationId(event.target.value)}
              aria-label="Salão"
            >
              {organizations.map((organization) => (
                <option key={organization.id} value={organization.id}>
                  {organization.name}
                </option>
              ))}
            </select>
          )}
          <button className="text-button" type="button" onClick={() => void supabase.auth.signOut()}>
            Sair
          </button>
        </div>
      </header>

      <main className="workspace-content">
        {selectedOrganizationId && selectedMembership && (
          <div className="auth-form">
            <UnitsPanel organizationId={selectedOrganizationId} role={selectedMembership.role} />
            <CatalogPanel organizationId={selectedOrganizationId} role={selectedMembership.role} />
          </div>
        )}
      </main>
    </div>
  )
}

export function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })

    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession)
      setLoading(false)
    })

    return () => data.subscription.unsubscribe()
  }, [])

  if (loading) {
    return <main className="app-shell loading-state">Carregando…</main>
  }

  if (!session) {
    return <AuthScreen />
  }

  return <SalonGate user={session.user} />
}
