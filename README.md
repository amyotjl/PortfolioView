# PortfolioView

Track personal stock portfolios and visualize them: candlestick chart of total portfolio
value, cash-flow-matched benchmark comparison (e.g. "would SPY have done better with my
exact deposits?"), allocation pies, and recurring transactions that materialize themselves.

**Stack:** Rails 8 (JSON API, Solid Queue/Cache) · Vue 3 + Vite + TypeScript · PostgreSQL 16 ·
Apache ECharts · PrimeVue + Tailwind. Market data: Tiingo (EOD prices, splits, dividends) + FMP (sector metadata).

The full design — schema, split-handling model, frozen API contract, milestones — lives in
[docs/PLAN.md](docs/PLAN.md). Read it before contributing; the split math and API contract
are load-bearing decisions.

## Running locally

```sh
docker compose up
```

- App: http://localhost:3000 (Rails) · http://localhost:5173 (Vite dev server, proxies /api)
- Postgres: localhost:5432 (user/password: `portfolio`)

First run installs gems and node modules into named volumes and prepares the databases.

## Development workflow

Work is tracked as GitHub issues labeled by specialist agent (`agent:backend-expert`,
`agent:database-expert`, `agent:ui-expert`, `agent:tester`, `agent:project-manager`),
grouped into milestones M0–M9. Agent definitions live in `.claude/agents/`.

## Secrets

API keys (Tiingo, FMP) go in `.env` (gitignored) — see `.env.example` once the price
pipeline lands (milestone M2).
