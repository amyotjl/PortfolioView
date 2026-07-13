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
      resources :portfolios, only: %i[ index show create update destroy ]

      # Analytics endpoints (backlog #031-#033). A SEPARATE additive block —
      # not folded into the CRUD `resources :portfolios` line above — so the
      # concurrently-added transactions/recurring/holdings nested resources
      # merge with minimal conflict. Rails merges the two portfolios route sets.
      resources :portfolios, only: [] do
        member do
          get :summary,     to: "summaries#show"
          get :allocations, to: "allocations#show"
        end
      end
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

  # Defines the root path route ("/")
  # root "posts#index"
end
