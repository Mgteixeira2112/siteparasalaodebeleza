# Sistema de Salão

Sistema de gerenciamento de salão de beleza.

## Front-end

Base inicial: React + TypeScript + Vite.

```bash
npm install
npm run dev
npm run typecheck
npm run build
```

## Backend

O backend usa o projeto Supabase compartilhado `mbsnmmhhvorkwmgzrnvi`, com isolamento lógico obrigatório por estruturas próprias do salão (`salon_*`).

O front-end não deve inventar campos ou estados de persistência. Contratos de dados novos devem ser definidos pelo PC 2 antes do consumo.

## Regra de contribuição

Alterações funcionais devem ser feitas em branches pequenas e integradas por Pull Request após CI verde e validação.
