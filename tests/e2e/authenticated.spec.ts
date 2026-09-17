import { expect, test } from '@playwright/test'

const email = process.env.E2E_EMAIL
const password = process.env.E2E_PASSWORD

test.describe('fluxo autenticado do salão', () => {
  test.skip(!email || !password, 'E2E_EMAIL e E2E_PASSWORD não configurados')

  test.beforeEach(async ({ page }) => {
    await page.goto('./')
    await page.getByLabel('E-mail').fill(email!)
    await page.getByLabel('Senha').fill(password!)
    await page.getByRole('button', { name: /entrar/i }).click()
    await expect(page.getByRole('button', { name: 'Sair' })).toBeVisible()
  })

  test('carrega os painéis operacionais principais', async ({ page }) => {
    await expect(page.getByRole('heading', { name: 'Hoje' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Caixa' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Disponibilidade' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Agenda' })).toBeVisible()
  })

  test('não grava pagamento quando a confirmação é cancelada', async ({ page }) => {
    const caixa = page.getByRole('heading', { name: 'Caixa' }).locator('..')
    const paymentButton = caixa.getByRole('button', { name: /Registrar quitação de/i }).first()

    await expect(
      paymentButton,
      'Homologação financeira exige uma comanda aberta com saldo na organização de teste.',
    ).toBeVisible()

    page.once('dialog', async (dialog) => {
      expect(dialog.type()).toBe('confirm')
      await dialog.dismiss()
    })

    await paymentButton.click()
    await expect(paymentButton).toBeVisible()
  })
})
