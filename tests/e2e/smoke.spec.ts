import { expect, test } from '@playwright/test'

test('abre o sistema publicado e exibe a autenticação', async ({ page }) => {
  await page.goto('/')

  await expect(page.getByRole('heading', { name: 'Sistema de Salão' })).toBeVisible()
  await expect(page.getByLabel('E-mail')).toBeVisible()
  await expect(page.getByLabel('Senha')).toBeVisible()
  await expect(page.getByRole('button', { name: /entrar/i })).toBeVisible()
})
