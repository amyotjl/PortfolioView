# Vendored skills — provenance

Installed 2026-07-10 after an adversarial review of online candidates (full text of every
SKILL.md read before install; folders scanned for command execution / remote fetches).

| Skill | Source | Pinned commit | License |
|---|---|---|---|
| `layered-rails` | github.com/palkan/skills (`layered-rails/skills/layered-rails/`) | `f4e8cd90ae388339d53bc05a3826034d0df56255` | none published — local use only, do not redistribute |
| `postgres`, `design-postgres-tables`, `postgres-database-migration` | github.com/timescale/pg-aiguide (`skills/…`) | `b4f11a45907af3abda0f79e784aff9a6d5eef468` | Apache-2.0 |
| `vue-best-practices` | github.com/vuejs-ai/skills (`skills/vue-best-practices/`) | `c9d355ff23f654309dd02006be671859df0a134c` | MIT |

Authored in-repo (ideas credited in the skill discovery review, no external code):

- `testing-conventions` — folds vetted ideas from anthropics/skills `webapp-testing` (Apache-2.0),
  citypaul/.dotfiles testing skills (MIT), and community RSpec conventions, rewritten for this
  project's Minitest + Vitest + Playwright(JS) stack.
- `project-management` — folds vetted ideas from mattpocock/skills `to-tickets` (MIT),
  TerminalSkills `prd-to-issues` (Apache-2.0), and the untrusted-input hygiene pattern; all
  gh usage is plain `gh`/`gh api`, no extensions, no bundled scripts.

Rejected during review (for the record): `ccpm` (14 bash scripts + third-party gh extension
executing over untrusted issue content), ruflo `github-project-management` (unpinned `npx`
remote execution by design), assorted 0-3 star personal repos (provenance too weak).

To update a vendored skill: re-clone at a new commit, re-run the review, update the pin here.
