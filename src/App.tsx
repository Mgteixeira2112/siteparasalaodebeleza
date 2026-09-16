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

const roleLabels: Record<string, string> = {
  owner: 'Proprietário',
  admin: 'Administrador',
  manager: 'Gerente',
  receptionist: 'Recepção',
  professional: 'Profissional',
  cashier: 'Caixa',
}

const unitManagerRoles = new Set(['owner', 'admin', 'manager'])

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

  const canManage = unitManagerRoles.has(role)

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
          <UnitsPanel organizationId={selectedOrganizationId} role={selectedMembership.role} />
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
