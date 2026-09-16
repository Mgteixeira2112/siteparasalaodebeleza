import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

type Comanda = {
  id: string
  client_id: string
  appointment_id: string
  status: string
  opened_at: string
}

type Line = {
  comanda_id: string
  description: string
  quantity: number
  total_price_cents: number
}

type Payment = {
  comanda_id: string
  amount_cents: number
}

type Client = { id: string; full_name: string }

type PaymentAttempt = {
  comandaId: string
  amountCents: number
  method: string
  requestId: string
}

const cashierRoles = new Set(['owner', 'admin', 'manager', 'receptionist', 'cashier'])
const methodLabels: Record<string, string> = {
  cash: 'Dinheiro',
  pix: 'Pix',
  debit_card: 'Cartão de débito',
  credit_card: 'Cartão de crédito',
  other: 'Outro',
}

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })
const amount = (cents: number) => money.format(cents / 100)

export function CashierPanel({ organizationId, role }: { organizationId: string; role: string }) {
  const [comandas, setComandas] = useState<Comanda[]>([])
  const [serviceLines, setServiceLines] = useState<Line[]>([])
  const [retailLines, setRetailLines] = useState<Line[]>([])
  const [payments, setPayments] = useState<Payment[]>([])
  const [clients, setClients] = useState<Client[]>([])
  const [method, setMethod] = useState('cash')
  const [pendingAttempt, setPendingAttempt] = useState<PaymentAttempt | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState('')
  const canPay = cashierRoles.has(role)

  async function loadComandas(): Promise<boolean> {
    setLoading(true)
    setMessage('')
    const { data, error } = await supabase
      .from('salon_comandas')
      .select('id, client_id, appointment_id, status, opened_at')
      .eq('organization_id', organizationId)
      .in('status', ['open', 'paid'])
      .order('opened_at', { ascending: false })
      .limit(30)

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return false
    }

    const nextComandas = (data ?? []) as Comanda[]
    if (nextComandas.length === 0) {
      setComandas([])
      setServiceLines([])
      setRetailLines([])
      setPayments([])
      setClients([])
      setLoading(false)
      return true
    }

    const comandaIds = nextComandas.map((comanda) => comanda.id)
    const clientIds = [...new Set(nextComandas.map((comanda) => comanda.client_id))]
    const [servicesResult, retailResult, paymentsResult, clientsResult] = await Promise.all([
      supabase
        .from('salon_comanda_items')
        .select('comanda_id, description, quantity, total_price_cents')
        .eq('organization_id', organizationId)
        .in('comanda_id', comandaIds),
      supabase
        .from('salon_comanda_retail_items')
        .select('comanda_id, description, quantity, total_price_cents')
        .eq('organization_id', organizationId)
        .in('comanda_id', comandaIds),
      supabase
        .from('salon_payments')
        .select('comanda_id, amount_cents')
        .eq('organization_id', organizationId)
        .in('comanda_id', comandaIds),
      supabase
        .from('salon_clients')
        .select('id, full_name')
        .eq('organization_id', organizationId)
        .in('id', clientIds),
    ])

    const relatedError = servicesResult.error ?? retailResult.error ?? paymentsResult.error ?? clientsResult.error
    if (relatedError) {
      setMessage(relatedError.message)
      setLoading(false)
      return false
    }

    setComandas(nextComandas)
    setServiceLines((servicesResult.data ?? []) as Line[])
    setRetailLines((retailResult.data ?? []) as Line[])
    setPayments((paymentsResult.data ?? []) as Payment[])
    setClients((clientsResult.data ?? []) as Client[])
    setLoading(false)
    return true
  }

  useEffect(() => {
    setPendingAttempt(null)
    setMethod('cash')
    void loadComandas()
    const channel = supabase
      .channel(`salon-cashier-${organizationId}`)
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'salon_appointments',
        filter: `organization_id=eq.${organizationId}`,
      }, () => void loadComandas())
      .subscribe()
    return () => { void supabase.removeChannel(channel) }
  }, [organizationId])

  async function pay(comanda: Comanda, balanceCents: number) {
    if (!canPay || busyId || comanda.status !== 'open' || balanceCents <= 0) return
    if (pendingAttempt && pendingAttempt.comandaId !== comanda.id) {
      setMessage('Confira a tentativa anterior antes de pagar outra comanda.')
      return
    }
    if (!pendingAttempt && !window.confirm(
      `Registrar pagamento recebido de ${amount(balanceCents)} via ${methodLabels[method]}? Esta ação grava um pagamento financeiro.`,
    )) return

    const attempt = pendingAttempt ?? {
      comandaId: comanda.id,
      amountCents: balanceCents,
      method,
      requestId: crypto.randomUUID(),
    }
    setPendingAttempt(attempt)
    setBusyId(comanda.id)
    setMessage('')

    const { data, error } = await supabase.rpc('salon_pay_comanda', {
      p_organization_id: organizationId,
      p_comanda_id: attempt.comandaId,
      p_amount_cents: attempt.amountCents,
      p_method: attempt.method,
      p_request_id: attempt.requestId,
    })

    if (error) {
      setMessage(`Pagamento não confirmado: ${error.message}. Atualize as comandas para conferir antes de repetir.`)
    } else {
      setPendingAttempt(null)
      const refreshed = await loadComandas()
      if (refreshed) {
        const result = data?.[0]
        setMessage(result?.comanda_status === 'paid'
          ? 'Pagamento registrado. Comanda paga.'
          : 'Pagamento registrado. Confira o saldo atualizado.')
      }
    }
    setBusyId(null)
  }

  const clientNames = new Map(clients.map((client) => [client.id, client.full_name]))

  return (
    <section className="auth-card compact-card">
      <h1>Caixa</h1>
      <p>Registre apenas pagamentos já recebidos. Esta tela não cobra cartão nem transfere Pix.</p>
      <button className="text-button" type="button" disabled={busyId !== null || loading}
        onClick={() => void loadComandas()}>Atualizar comandas</button>
      {message && <p className="form-message" role="alert">{message}</p>}
      {loading && <span className="loading-state">Carregando…</span>}
      {!loading && comandas.length === 0 && <span className="loading-state">Nenhuma comanda aberta ou paga.</span>}
      {!loading && comandas.map((comanda) => {
        const lines = [...serviceLines, ...retailLines].filter((line) => line.comanda_id === comanda.id)
        const totalCents = lines.reduce((sum, line) => sum + Number(line.total_price_cents), 0)
        const paidCents = payments.filter((payment) => payment.comanda_id === comanda.id)
          .reduce((sum, payment) => sum + Number(payment.amount_cents), 0)
        const balanceCents = totalCents - paidCents
        return (
          <div className="auth-form" key={comanda.id}>
            <strong>{clientNames.get(comanda.client_id) ?? 'Cliente'} · {comanda.status === 'paid' ? 'Paga' : 'Aberta'}</strong>
            {lines.map((line, index) => (
              <span key={`${comanda.id}:${index}`}>
                {line.description} · {line.quantity} × · {amount(Number(line.total_price_cents))}
              </span>
            ))}
            <strong>Total: {amount(totalCents)} · Pago: {amount(paidCents)} · Saldo: {amount(balanceCents)}</strong>
            {canPay && comanda.status === 'open' && balanceCents > 0 && (
              <div className="auth-form">
                <label>
                  Forma de pagamento
                  <select value={method} disabled={busyId !== null || pendingAttempt !== null}
                    onChange={(event) => setMethod(event.target.value)}>
                    {Object.entries(methodLabels).map(([value, label]) =>
                      <option key={value} value={value}>{label}</option>)}
                  </select>
                </label>
                <button className="primary-button" type="button"
                  disabled={busyId !== null || loading || (pendingAttempt !== null && pendingAttempt.comandaId !== comanda.id)}
                  onClick={() => void pay(comanda, balanceCents)}>
                  {pendingAttempt?.comandaId === comanda.id ? 'Repetir tentativa' : `Registrar quitação de ${amount(balanceCents)}`}
                </button>
              </div>
            )}
          </div>
        )
      })}
    </section>
  )
}
