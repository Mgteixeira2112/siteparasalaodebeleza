const target = process.env.E2E_BASE_URL
if (!target) throw new Error('E2E_BASE_URL não configurada.')

const deadline = Date.now() + 360_000
let lastError = 'nenhuma resposta'

while (Date.now() < deadline) {
  try {
    const response = await fetch(target, {
      headers: { 'Cache-Control': 'no-cache' },
      signal: AbortSignal.timeout(12_000),
    })
    const html = await response.text()
    if (response.status === 200 && /<title>\s*Sistema de Salão\s*<\/title>/i.test(html) && html.includes('id="root"')) {
      console.log(`GitHub Pages acessível e servindo o aplicativo: HTTP ${response.status}`)
      process.exit(0)
    }
    lastError = `HTTP ${response.status}; HTML do aplicativo ${html.includes('id="root"') ? 'presente' : 'ausente'}`
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error)
  }
  console.log(`Pages ainda indisponível: ${lastError}. Nova tentativa em 10 segundos.`)
  await new Promise((resolve) => setTimeout(resolve, 10_000))
}

throw new Error(`Deploy não homologado: ${target} continua indisponível (${lastError}). Verifique Settings → Pages → Source = GitHub Actions e o domínio configurado; um job de deploy verde não substitui uma resposta HTTP 200.`)
