MaintenanceOnSteroids::Engine.routes.draw do
  get "dashboard", to: "dashboard#index", as: :dashboard

  resources :jobs, only: %i[index show] do
    member do
      get :source
    end
    resources :runs, only: %i[new create]
  end

  resources :runs, only: %i[show] do
    member do
      post :pause
      post :resume
      post :cancel
      get  :status
      get  "artifacts/:artifact_id/download", action: :artifact_download, as: :artifact_download
    end
  end

  root to: "dashboard#index"
end
