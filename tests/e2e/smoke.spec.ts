import { expect, test } from '@playwright/test'

test('abre o sistema e exibe a autenticação', async ({ page }) => {
  // './' mantém o caminho /siteparasalaodebeleza/ configurado em baseURL.
  const response = await page.goto('./')

  expect(response, 'O navegador não recebeu resposta do site.').not.toBeNull()
  expect(response?.status(), 'O endereço configurado deve servir o aplicativo, não uma página 404.').toBe(200)
  await expect(page.getByRole('heading', { name: 'Sistema de Salão' })).toBeVisible()
  await expect(page.getByLabel('E-mail')).toBeVisible()
  await expect(page.getByLabel('Senha')).toBeVisible()
  await expect(page.getByRole('button', { name: /entrar/i })).toBeVisible()
})
