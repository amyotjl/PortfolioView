# PortfolioView

Track personal stock portfolios and visualize them: candlestick chart of total portfolio
value, cash-flow-matched benchmark comparison (e.g. "would SPY have done better with my
exact deposits?"), allocation pies, and recurring transactions that materialize themselves.

**Stack:** Rails 8 (JSON API, Solid Queue/Cache) · Vue 3 + Vite + TypeScript · PostgreSQL 16 ·
Apache ECharts · PrimeVue + Tailwind. Market data: Tiingo (EOD prices, splits, dividends) + FMP (sector metadata).

The full design — schema, split-handling model, frozen API contract, milestones — lives in
[docs/PLAN.md](docs/PLAN.md). Read it before contributing; the split math and API contract
are load-bearing decisions.

**AI agents working in this repo**: start with [CLAUDE.md](CLAUDE.md) (environment gotchas,
commit/merge conventions) and [docs/STATUS.md](docs/STATUS.md) (live milestone/issue
tracker), then PLAN.md and [docs/API_SHAPES.md](docs/API_SHAPES.md) (as-built API contract).

## Running locally (development)

```sh
docker compose up
```

- App: http://localhost:3000 (Rails) · http://localhost:5173 (Vite dev server, proxies /api)
- Postgres: localhost:5433 (user/password: `portfolio`) — host port 5433, not 5432, because
  5432 is commonly held by another local Postgres. In-network services still use `db:5432`.

First run installs gems and node modules into named volumes and prepares the databases.

## Production (local deploy)

One `web-prod` container (Rails in production mode, the Vue SPA served from the same origin,
Solid Queue embedded in Puma, fronted by Thruster) plus one `db-prod` Postgres container with
its own named volume. Both live behind the compose `production` profile, so they never start
with a plain `docker compose up`.

### Bootstrap from a clean checkout

```sh
# 1. Configure secrets. Production has NO defaults for these — a blank value
#    fails closed rather than booting with a dev-shaped secret.
cp .env.example .env
#    Then fill in, in .env:
#      SECRET_KEY_BASE=$(openssl rand -hex 64)
#      APP_DATABASE_PASSWORD=$(openssl rand -hex 24)
#      INVITE_CODE=<your own value>       # blank => registration stays closed
#      TIINGO_API_KEY / FMP_API_KEY / TWELVE_DATA_API_KEY as available
#      INTERNAL_API_TOKEN=$(openssl rand -hex 32)
#        Optional, and blank => the /api/internal namespace stays CLOSED.
#        Set it only if you want to trigger a sync from cron or curl; the
#        Settings "Sync now" button uses your session and needs no token.
#        Note a blank value makes the endpoint answer 401 to every request,
#        including a correct token — that is fail-closed, not a bug.

# 2. Build the image (multi-stage: `npm ci && npm run build`, then Rails) and
#    start both services. Naming the services is what keeps the dev containers,
#    which have no profile and would fight over :3000, out of the run.
docker compose --profile production up --build -d db-prod web-prod

# 3. Watch the first boot. bin/docker-entrypoint clears any stale
#    tmp/pids/server.pid and runs `bin/rails db:prepare` before starting the
#    server. That creates app_production plus the app_production_queue /
#    _cache / _cable databases, loads the schema, and — because the database is
#    brand new — runs db/seeds.rb for the benchmark list (SPY, VTI, QQQ).
#    There is no separate migrate or seed step on a fresh volume.
docker compose --profile production logs -f web-prod
```

Re-running the seeds later (they are idempotent) if you ever need to:

```sh
docker compose --profile production exec web-prod ./bin/rails db:seed
```

The app is then at **http://localhost:3000** — deep links such as
`http://localhost:3000/portfolios/1` are served by the SPA catch-all route, so a refresh or a
bookmarked URL boots the client router instead of 404ing.

Useful follow-ups:

```sh
docker compose --profile production ps                 # health status
docker compose --profile production restart web-prod   # data survives: named volume
docker compose --profile production down               # stop, keep the volume
docker compose --profile production down -v            # stop AND destroy the data
```

Notes:

- Thruster listens on port 80 inside the container and proxies to Puma; compose publishes it
  as `3000:80`. `db-prod` publishes no host port at all.
- The hashed Vite assets under `public/assets` are served with a one-year cache; the SPA shell
  (`index.html`) is served by `SpaController` with `Cache-Control: no-store`, so a rebuilt
  image is picked up on the next page load rather than a year later.
- Never run the dev stack and the production profile at the same time — both want
  `localhost:3000`.

## Development workflow

Work is tracked as GitHub issues labeled by specialist agent (`agent:backend-expert`,
`agent:database-expert`, `agent:ui-expert`, `agent:tester`, `agent:project-manager`),
grouped into milestones M0–M9. Agent definitions live in `.claude/agents/`.

## Secrets

API keys (Tiingo, FMP) go in `.env` (gitignored) — see `.env.example` once the price
pipeline lands (milestone M2).
