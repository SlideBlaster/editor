defmodule SbAuth.GitHub do
  @moduledoc """
  Thin GitHub REST client for the auth flow: OAuth code exchange, identity, and
  the authorize-then-mint path that yields a single-repo installation token.

  Every mint is authorized against the *user's own* installations (no confused
  deputy): we only mint for a repo the signed-in user can actually reach through
  an installation of our App.
  """
  alias SbAuth.AppJwt

  @api "https://api.github.com"
  @oauth "https://github.com/login/oauth/access_token"

  # --- OAuth (user-to-server) ---

  @doc "Exchange an OAuth `code` for a user access token."
  def exchange_code(code) do
    cfg = cfg()

    case Req.post(@oauth,
           json: %{
             client_id: cfg[:github_client_id],
             client_secret: cfg[:github_client_secret],
             code: code
           },
           headers: [{"accept", "application/json"}],
           retry: :transient
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{body: body}} -> {:error, {:oauth_exchange, body}}
      {:error, reason} -> {:error, {:oauth_exchange, reason}}
    end
  end

  @doc "Resolve the signed-in user's identity from their access token."
  def get_user(user_token) do
    case Req.get(@api <> "/user", headers: user_headers(user_token)) do
      {:ok, %{status: 200, body: b}} ->
        {:ok, %{login: b["login"], name: b["name"], avatar_url: b["avatar_url"]}}

      other ->
        {:error, {:get_user, other}}
    end
  end

  # --- Authorize + mint ---

  @doc """
  Mint a single-repo, `contents:write`, ≤1h installation token for `owner/name`,
  but only if `user_token`'s owner can access it through an App installation.

  Returns `{:ok, %{value, expires_at}}`, `{:error, :no_repo_access}`, or
  `{:error, reason}`.
  """
  def mint_repo_token(user_token, owner, name) do
    with {:ok, installation_id} <- installation_for_repo(owner, name),
         {:ok, repo_id} <- authorize_user_repo(user_token, installation_id, owner, name),
         {:ok, token, expires_at} <- installation_token(installation_id, repo_id) do
      {:ok, %{value: token, expires_at: expires_at}}
    end
  end

  # The App installation that covers owner/name (authenticated AS the App).
  defp installation_for_repo(owner, name) do
    with {:ok, jwt} <- AppJwt.generate() do
      case Req.get(@api <> "/repos/#{owner}/#{name}/installation", headers: app_headers(jwt)) do
        {:ok, %{status: 200, body: %{"id" => id}}} -> {:ok, id}
        {:ok, %{status: 404}} -> {:error, :no_repo_access}
        other -> {:error, {:installation_lookup, other}}
      end
    end
  end

  # Confirm THIS user can reach owner/name through that installation, and return
  # the repo id. 404 here means the user is not part of the installation.
  defp authorize_user_repo(user_token, installation_id, owner, name) do
    full = String.downcase("#{owner}/#{name}")
    url = @api <> "/user/installations/#{installation_id}/repositories?per_page=100"

    case Req.get(url, headers: user_headers(user_token)) do
      {:ok, %{status: 200, body: %{"repositories" => repos}}} ->
        case Enum.find(repos, &(String.downcase(&1["full_name"] || "") == full)) do
          %{"id" => id} -> {:ok, id}
          _ -> {:error, :no_repo_access}
        end

      {:ok, %{status: s}} when s in [403, 404] ->
        {:error, :no_repo_access}

      other ->
        {:error, {:authorize_user_repo, other}}
    end
  end

  # Mint the scoped installation token (authenticated AS the App).
  defp installation_token(installation_id, repo_id) do
    with {:ok, jwt} <- AppJwt.generate() do
      body = %{repository_ids: [repo_id], permissions: %{contents: "write"}}

      case Req.post(@api <> "/app/installations/#{installation_id}/access_tokens",
             json: body,
             headers: app_headers(jwt)
           ) do
        {:ok, %{status: 201, body: %{"token" => token, "expires_at" => expires_at}}} ->
          {:ok, token, expires_at}

        other ->
          {:error, {:mint_token, other}}
      end
    end
  end

  # --- headers ---

  defp user_headers(token) do
    [{"authorization", "Bearer " <> token} | base_headers()]
  end

  defp app_headers(jwt) do
    [{"authorization", "Bearer " <> jwt} | base_headers()]
  end

  defp base_headers do
    [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
  end

  defp cfg, do: Application.get_env(:sb_auth, SbAuth)
end
