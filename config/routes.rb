Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resource :session, only: %i[ show create destroy ]
      resource :registration, only: %i[ create ]

      resources :instruments, only: [] do
        get :search, on: :collection
        get :price, on: :member
      end

      resources :benchmarks, only: %i[ index ]

      # Session-authenticated "Sync now" (issue #56, used by the Settings page
      # in #57). The browser cannot hold the internal bearer token, so the SPA
      # gets its own door onto the same Prices::SyncTrigger — normal session +
      # CSRF + error envelope. See Api::V1::SyncsController.
      # GET reads the price-cache freshness snapshot the Settings page renders;
      # POST triggers the sync. Same resource, so the pair reads coherently.
      resource :sync, only: %i[ show create ]

      # Portfolio export/import (backlog #064). Declared as COLLECTION routes on
      # the portfolios resource so /portfolios/export is matched before the
      # /portfolios/:id member route could swallow "export" as an id.
      resources :portfolios, only: %i[ index show create update destroy ] do
        collection do
          get  :export, to: "portfolio_transfers#export"
          post :import, to: "portfolio_transfers#import"
        end
      end

      # Portfolio-scoped endpoints (backlog #028-#033), nested under the
      # portfolios CRUD line above. Transactions/recurring/holdings CRUD plus
      # the analytics member routes (candles/summary/allocations).
      resources :portfolios, only: [] do
        resources :transactions, only: %i[ index create update destroy ]
        # Liquid cash (issue #80). Its own endpoint, never merged into
        # transactions: a cash movement has no symbol/side/shares/price, and a
        # union row shape would throw in every consumer's zod schema.
        resources :cash_transactions, only: %i[ index create update destroy ]
        resources :recurring_transactions, only: %i[ index show create update destroy ] do
          post :preview, on: :collection
        end
        resource :holdings, only: %i[ show ]
        member do
          get :candles,     to: "candles#show"
          get :summary,     to: "summaries#show"
          get :allocations, to: "allocations#show"
        end
      end
    end

    # Machine-to-machine job triggers (docs/PLAN.md § Deployment; issue #56).
    # Bearer-token guarded via INTERNAL_API_TOKEN, deliberately outside /v1:
    # no session, no CSRF pair, no user. For cron / external callers only —
    # the SPA uses POST /api/v1/sync above.
    namespace :internal do
      post "jobs/daily_sync", to: "jobs#daily_sync"
    end
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Unmatched /api/* paths answer with the JSON error envelope, never an HTML
  # 404 (docs/PLAN.md § API contract). MUST remain the last /api route so every
  # real endpoint above is matched first.
  match "/api/*unmatched", to: "errors#not_found", via: :all, format: false

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # SPA catch-all (docs/PLAN.md § Architecture; backlog #054). Everything that
  # isn't a real route and isn't a file under public/ renders the Vue shell, so
  # a deep link like /portfolios/1 or a browser refresh boots the client router
  # instead of 404ing.
  #
  # MUST stay last in this file. Routes are matched top-down, so every /api/v1
  # endpoint, /up, and the /api/* JSON-404 catch-all above are all matched
  # first. The constraint is belt-and-braces for the two paths a glob could
  # still reach: bare "/api" (which the /api/*unmatched glob needs a trailing
  # segment to match) and the Rails-internal /rails/* engine routes.
  #
  # GET-only on purpose: an unknown non-/api POST stays a routing 404 rather
  # than being handed an HTML page.
  #
  # "/cable" joins the list because #74 UNMOUNTED Action Cable
  # (`config.action_cable.mount_path = nil`). While it was mounted, its own
  # middleware answered a plain GET /cable with a 404 and the glob never saw the
  # path; unmounted, /cable is just another unmatched path and this glob would
  # answer it 200 with the Vue shell. That would be a regression in the exact
  # property #58 verified and #74's acceptance criteria restate, so the constraint
  # keeps /cable a 404 rather than a page.
  root to: "spa#show"
  get "*path", to: "spa#show", format: false,
      constraints: ->(request) { !request.path.start_with?("/api", "/rails/", "/cable") }
end
