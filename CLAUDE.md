# PortfolioView — agent orientation

Portfolio-tracking web app: Rails 8 JSON API + Vue 3 SPA + PostgreSQL, deployed locally via
Docker Compose. Built by a team of specialist Claude Code agents (`.claude/agents/`)
coordinated by an orchestrating session, tracked as GitHub issues grouped into milestones.

**Read in this order, only as deep as your task needs:**
1. This file — operational facts and gotchas that apply to every session, regardless of role.
2. [docs/STATUS.md](docs/STATUS.md) — current milestone/issue state. Check this before
   running `gh issue list` for a full status picture — it's usually enough. Still use
   `gh issue view N` for one issue's exact acceptance criteria when implementing/verifying it.
3. [docs/PLAN.md](docs/PLAN.md) — the frozen design: schema, split-math model, API
   contract, milestone definitions. Source of truth for *intent*.
4. [docs/API_SHAPES.md](docs/API_SHAPES.md) — as-built response shapes, tester-verified
   live against the running API. Source of truth for *what the API actually returns* — a
   few deliberate deviations from PLAN.md are documented there; don't "fix" them.
5. Your matching `.claude/agents/*.md` file — domain invariants + role-specific conventions.

## Stack
Rails 8.1 (NOT `--api` mode — cookie/session + CSRF for the same-origin SPA), Solid Queue +
Solid Cache (Postgres-backed, no Redis), PostgreSQL 16. Vue 3.5 `<script setup>` + TS strict
+ Vite, Pinia + Pinia Colada, PrimeVue 4 unstyled + Tailwind 4, Apache ECharts, vee-validate
+ zod. Data: Tiingo (prices/splits/dividends), FMP (sector metadata), Twelve Data
(forward-delta fallback only — never backfills, never ingests splits).

## Environment gotchas (read before touching Docker/DB)
- **DB host port is 5433, not 5432** — `docker-compose.yml` maps it there because 5432 is
  commonly held by other local Postgres instances on this machine. In-network services
  (web, vite) still reach it at `db:5432`; only the host-side port changed.
- **Real API keys live in `.env`** (gitignored). `.env.example` is a template only — it has
  been accidentally filled with real keys and committed twice already. If you ever see a
  real-looking key in a *tracked* file, move it to `.env` (never print/log it) and restore
  the template with `git checkout HEAD -- .env.example`; don't just leave a note.
- **Test env blanks provider keys** (`config/environments/test.rb` nils out
  `TIINGO_API_KEY`/`TWELVE_DATA_API_KEY`/`FMP_API_KEY`) so the suite is hermetic and never
  silently depends on a real network call. Don't remove that.
- **Multi-DB dev config** (`app_development_queue`/`app_development_cache` databases,
  alongside the primary) is required for Solid Queue/Solid Cache — don't simplify back to a
  single dev database.
- `docker-compose.yml`'s `web` command runs `rm -f tmp/pids/server.pid` before booting —
  needed because a stale pidfile left on the bind mount by any unclean shutdown otherwise
  aborts boot with "a server is already running".
- `.gitattributes` forces LF everywhere — containers execute these files, and CRLF corrupts
  shell scripts silently on a Windows host.
- If the A:-drive Docker bind mount goes stale (files that exist error "no such file or
  directory", or the repo looks partially present), **stop and report it — don't restart
  Docker Desktop yourself.**

## Frontend: node:22-only rule
Host Node is v20; `frontend/node_modules` is installed inside Linux containers and is
**binary-incompatible with a host run**. Never run `npm`/`vitest`/`vite`/`vue-tsc` on the
host. Always use a disposable container:
```
docker run --rm -v "<worktree-path>:/app" -w /app/frontend node:22 bash -c "..."
```
Never publish host ports from these ad-hoc containers — 3000/5173/5433 are held by the
primary dev stack; curl from *inside* the same container to check a dev-server boot. On
Windows, prefer the PowerShell tool over Bash/git-bash for these docker invocations —
git-bash mangles Windows paths passed to `-v`/`-w` into POSIX-ish nonsense.

Version pins are deliberate, not oversights — don't "helpfully" bump them:
- **PrimeVue 4.5.5**, **vue-router 4.6.4** — npm's current latest are v5 majors; the plan
  locks v4 for both.
- **zod 4**, with `@vee-validate/zod`'s zod-3 peer resolved via a `package.json`
  `overrides` entry (`{"@vee-validate/zod":{"zod":"$zod"}}`) — no `--legacy-peer-deps`, no
  `.npmrc`. Verified working end-to-end (a runtime probe proved `toTypedSchema` validates
  zod-4 schemas correctly). Reuse the pattern; don't remove it.

## Parallel work: isolated worktrees + isolated compose stacks
Independent slices of work run in `Agent(..., isolation: "worktree")`. To also run a full
Docker stack from inside that worktree without colliding with the primary dev stack (ports
3000/5173/5433) or another agent's isolated stack:
1. In the worktree, write an **uncommitted** `docker-compose.isolated.yml`:
   ```yaml
   services:
     db:   { ports: !override [] }
     web:  { ports: !override [] }
     vite: { ports: !override [] }
   ```
2. Run everything with a **unique** `-p <project-name>` (e.g. `pv_m6`, `pv_fix5960`) so
   volumes/networks/containers never collide with another running stack.
3. Tear down with `docker compose -p <name> -f docker-compose.yml -f
   docker-compose.isolated.yml down -v` and **delete the yml** before reporting — the
   worktree's `git status` should be clean.

## Commit discipline
**Commit eagerly — one commit per backlog issue, as soon as it's coherent.** Agent sessions
have repeatedly hit provider session limits mid-task; committed work survives a restart,
uncommitted work doesn't. Commit messages should reference `Closes #N` — merging the branch
to `main` auto-closes the GitHub issue.

## The merge gate
No branch merges without an independent tester-agent verdict. The tester re-runs every gate
itself (never trusts the implementer's report at face value), writes non-vacuity/mutation
probes (revert just the fix, confirm the new test fails for the right reason, restore), and
for API-facing frontend work validates zod schemas against **live** API responses, not just
hand-built fixtures — this is how a real nullability bug in `/instruments/search` was caught
before merge. The tester posts evidence comments on the issue(s) but does **not** close them;
only merging the `Closes #N` commit closes an issue. Only the orchestrating session (or a
dispatched `project-manager` agent) merges branches and closes milestones.

## GitHub issue numbering
Backlog file number + 4 = GitHub issue number (e.g. backlog `034` → issue `#38`). Issues
#1–4 predate backlog-driven work and aren't separately tracked.

## Known deliberate contract quirks
See "Known envelope inconsistency" in [docs/API_SHAPES.md](docs/API_SHAPES.md) — e.g.
`/candles` is a bare object while `/summary`/`/allocations` are wrapped. These are as-built
and intentional; don't "fix" them without a PLAN.md amendment and a tester sign-off.

## Tracked open defects & enhancements
See [docs/STATUS.md](docs/STATUS.md) for the live list. Keep that file current — update it
in the same session you close an issue/milestone or learn of a new one.
