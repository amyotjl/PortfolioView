# syntax=docker/dockerfile:1
# check=error=true

# Production image for PortfolioView (docs/PLAN.md § Deployment, backlog #054).
#
# Multi-stage:
#   frontend -> `npm ci && npm run build` produces the Vite bundle
#   build    -> gems + bootsnap precompile (throw-away, keeps the final image small)
#   final    -> Ruby slim runtime + the app + the SPA build, started via Thruster
#
# This Dockerfile is production-only. The dev stack in docker-compose.yml runs
# bind-mounted `ruby:3.4` / `node:22` containers instead and never builds this.
#
# Build and run it through the compose production profile:
#   docker compose --profile production up --build -d db-prod web-prod
# See README.md § Production (local deploy) for the full bootstrap.

# Keep in sync with .ruby-version.
ARG RUBY_VERSION=3.4.10
# Keep in sync with the node:22 rule in CLAUDE.md § Frontend.
ARG NODE_VERSION=22


# ---------------------------------------------------------------------------
# Stage 1 — build the Vue 3 SPA
# ---------------------------------------------------------------------------
FROM docker.io/library/node:${NODE_VERSION} AS frontend

WORKDIR /build/frontend

# Manifest first: a source-only change then reuses the cached install layer.
# `npm ci` (never `npm install`) so the deliberate pins — PrimeVue 4,
# vue-router 4, and the zod-4 `overrides` entry — resolve exactly as locked
# (CLAUDE.md § Version pins are deliberate).
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY frontend/ ./

# `npm run build` is `vue-tsc -b && vite build`, so a TypeScript error fails the
# image build rather than shipping a bundle nobody type-checked.
RUN npm run build


# ---------------------------------------------------------------------------
# Stage 2 — Rails runtime base
# ---------------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages. postgresql-client is needed by db:prepare/pg_isready,
# curl by the compose healthcheck.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# BUNDLE_WITHOUT drops :development AND :test — this Gemfile keeps them as two
# separate groups, so omitting :test is what keeps capybara/selenium out of the
# production image.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"


# ---------------------------------------------------------------------------
# Stage 3 — throw-away gem build stage
# ---------------------------------------------------------------------------
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/


# ---------------------------------------------------------------------------
# Stage 4 — final image
# ---------------------------------------------------------------------------
FROM base

# Run and own only the runtime files as a non-root user for security. The USER
# switch happens after the copies below, because the `mv` that relocates
# index.html has to create /rails/spa and WORKDIR made /rails itself root-owned.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# The SPA build (docs/PLAN.md § Architecture: "prod serves the Vite build from
# Rails public/ with an SPA catch-all route"). Hashed assets land under
# public/assets and are served straight off disk with production.rb's
# far-future cache headers — they are content-addressed, so that is correct.
#
# index.html is then moved OUT of public/ on purpose. It is the one file that
# must never be cached (it names the current asset hashes), and anything left at
# public/index.html would be served by ActionDispatch::Static for "/" *before*
# routing, inheriting that same one-year max-age. Serving it from /rails/spa
# forces every request for the shell — "/" and deep links alike — through
# SpaController, which sends it with no-store.
COPY --chown=rails:rails --from=frontend /build/frontend/dist/ /rails/public/
RUN mkdir -p /rails/spa && \
    mv /rails/public/index.html /rails/spa/index.html && \
    chown -R rails:rails /rails/spa

USER 1000:1000

# Entrypoint clears a stale pidfile and prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime.
# Thruster listens on :80 and proxies to Puma on TARGET_PORT (3000) in-process;
# the compose production profile publishes it as localhost:3000.
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
