defmodule SbAuthWeb.AuthController do
  @moduledoc """
  The Auth-service HTTP contract (identical to `services/auth-stub`), backed by
  real GitHub OAuth + installation-token minting. The browser `BrowserAuthAdapter`
  cannot tell this from the stub — that is the drop-in test.

  Session id in the HttpOnly `sb_session` cookie; the double-submit csrf in the
  readable `sb_csrf` cookie, required as `x-sb-csrf` on state-changing routes.
  """
  use SbAuthWeb, :controller

  alias SbAuth.{GitHub, SessionStore}

  @session_cookie "sb_session"
  @csrf_cookie "sb_csrf"

  # GET /auth/github?return_to= — begin real user-to-server OAuth.
  def start(conn, params) do
    return_to = safe_return_to(params["return_to"])
    state = SessionStore.put_pending(return_to)

    query =
      URI.encode_query(%{
        "client_id" => cfg()[:github_client_id],
        "state" => state
      })

    redirect(conn, external: "https://github.com/login/oauth/authorize?" <> query)
  end

  # GET /auth/github/callback?code=&state= — exchange, identify, open a session.
  def callback(conn, params) do
    return_to = SessionStore.take_pending(params["state"]) || web_shell_origin()

    with code when is_binary(code) <- params["code"],
         {:ok, user_token} <- GitHub.exchange_code(code),
         {:ok, identity} <- GitHub.get_user(user_token) do
      session = SessionStore.create(%{user_token: user_token, identity: identity})

      conn
      |> put_session_cookies(session)
      |> redirect(external: return_to)
    else
      _ -> redirect(conn, external: append_query(web_shell_origin(), "auth=error"))
    end
  end

  # GET /me — current identity, or 401.
  def me(conn, _params) do
    case current_session(conn) do
      %{identity: identity} -> json(conn, identity_json(identity))
      _ -> send_json(conn, 401, %{error: "unauthenticated"})
    end
  end

  # GET /capabilities — server-authoritative flags (free tier for the slice).
  def capabilities(conn, _params) do
    case current_session(conn) do
      nil -> send_json(conn, 401, %{error: "unauthenticated"})
      _ -> json(conn, %{managedStorage: false, premiumCollab: false, seatCap: 1})
    end
  end

  # POST /mint {owner,name,scope} — authorize + mint a single-repo token.
  def mint(conn, params) do
    with {:session, %{} = session} <- {:session, current_session(conn)},
         {:csrf, true} <- {:csrf, csrf_ok?(conn, session)},
         owner when is_binary(owner) <- params["owner"],
         name when is_binary(name) <- params["name"],
         {:ok, %{value: value, expires_at: expires_at}} <-
           GitHub.mint_repo_token(session.user_token, owner, name) do
      json(conn, %{value: value, expiresAt: expires_at})
    else
      {:session, _} -> send_json(conn, 401, %{error: "unauthenticated"})
      {:csrf, _} -> send_json(conn, 403, %{error: "bad_csrf"})
      {:error, :no_repo_access} -> send_json(conn, 403, %{error: "no_repo_access"})
      _ -> send_json(conn, 502, %{error: "mint_failed"})
    end
  end

  # POST /signout — drop the session, expire cookies.
  def signout(conn, _params) do
    conn
    |> session_id()
    |> SessionStore.delete()

    conn
    |> clear_session_cookies()
    |> send_resp(204, "")
  end

  # Safety net: the Cors plug normally answers OPTIONS before dispatch.
  def cors_preflight(conn, _params), do: send_resp(conn, 204, "")

  # --- session/cookie helpers ---

  defp current_session(conn), do: conn |> session_id() |> SessionStore.get()

  defp session_id(conn) do
    conn = fetch_cookies(conn)
    conn.req_cookies[@session_cookie]
  end

  defp csrf_ok?(conn, session) do
    header = conn |> get_req_header("x-sb-csrf") |> List.first()
    is_binary(header) and header == session.csrf
  end

  defp put_session_cookies(conn, %{id: id, csrf: csrf}) do
    conn
    |> put_resp_cookie(@session_cookie, id, cookie_opts(true))
    |> put_resp_cookie(@csrf_cookie, csrf, cookie_opts(false))
  end

  defp clear_session_cookies(conn) do
    conn
    |> delete_resp_cookie(@session_cookie, cookie_opts(true))
    |> delete_resp_cookie(@csrf_cookie, cookie_opts(false))
  end

  defp cookie_opts(http_only?) do
    [
      http_only: http_only?,
      secure: !!cfg()[:secure_cookies],
      same_site: cfg()[:same_site] || "Lax",
      path: "/"
    ]
  end

  # --- misc ---

  defp identity_json(%{login: login, name: name, avatar_url: avatar}) do
    %{login: login, name: name, avatarUrl: avatar}
  end

  # Accept a bare path, or an absolute URL whose origin is the allowed web shell;
  # otherwise fall back to the web-shell root. Prevents open-redirect abuse.
  defp safe_return_to(nil), do: web_shell_origin()

  defp safe_return_to(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "/") -> web_shell_origin() <> value
      String.starts_with?(value, web_shell_origin()) -> value
      true -> web_shell_origin()
    end
  end

  defp append_query(url, query) do
    sep = if String.contains?(url, "?"), do: "&", else: "?"
    url <> sep <> query
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp web_shell_origin, do: cfg()[:web_shell_origin] || "http://localhost:5173"
  defp cfg, do: Application.get_env(:sb_auth, SbAuth)
end
