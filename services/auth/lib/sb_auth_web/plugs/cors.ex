defmodule SbAuthWeb.Plugs.Cors do
  @moduledoc """
  Minimal credentialed CORS for the web shell.

  Same-origin dev goes through the Vite proxy and needs no CORS, but a cross-origin
  shell (custom `VITE_SB_AUTH_URL`) does: echo the request `Origin` only when it
  matches the configured web-shell origin, allow credentials, and answer the
  `OPTIONS` preflight that `/mint` (custom `x-sb-csrf` header) triggers.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()

    conn =
      if origin && origin == allowed_origin() do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-credentials", "true")
        |> put_resp_header("vary", "origin")
      else
        conn
      end

    if conn.method == "OPTIONS" do
      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type, x-sb-csrf")
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp allowed_origin do
    Application.get_env(:sb_auth, SbAuth)[:web_shell_origin] || "http://localhost:5173"
  end
end
