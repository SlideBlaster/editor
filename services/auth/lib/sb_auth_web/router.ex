defmodule SbAuthWeb.Router do
  use SbAuthWeb, :router

  pipeline :api do
    plug SbAuthWeb.Plugs.Cors
    plug :accepts, ["json"]
  end

  scope "/", SbAuthWeb do
    pipe_through :api

    get "/auth/github", AuthController, :start
    get "/auth/github/install", AuthController, :install
    get "/auth/github/callback", AuthController, :callback
    get "/me", AuthController, :me
    get "/capabilities", AuthController, :capabilities
    post "/mint", AuthController, :mint
    post "/signout", AuthController, :signout

    # Preflight for the state-changing routes (custom x-sb-csrf header).
    # The Cors plug answers OPTIONS in the pipeline; the action is a safety net.
    options "/mint", AuthController, :cors_preflight
    options "/signout", AuthController, :cors_preflight
  end
end
