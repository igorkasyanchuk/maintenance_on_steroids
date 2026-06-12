Rails.application.routes.draw do
  devise_for :users

  mount MaintenanceOnSteroids::Engine, at: "/maintenance"

  root to: "home#index"
end
