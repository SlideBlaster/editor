defmodule SbAuth.SessionStore do
  @moduledoc """
  In-memory (ETS) session + pending-OAuth store for the vertical slice.

  One table, `:public`, holds two kinds of record keyed by an opaque token:

    * a **session** — `%{user_token, identity, csrf, created_at}` (the signed-in
      user's GitHub access token + identity). The `sb_session` cookie carries the
      key; `sb_csrf` carries the csrf for double-submit.
    * a **pending** OAuth handoff — `%{return_to}` created before the redirect to
      GitHub and consumed (once) on callback via the `state` nonce.

  Deliberately not durable: the KMS/hardening pass swaps this for Postgres/Redis
  when the service goes multi-node. Sessions live only in this process's memory.
  """
  use GenServer

  @table :sb_auth_sessions

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Create a session record; returns `%{id, csrf}` and stores it."
  def create(record) when is_map(record) do
    id = token()
    csrf = token()

    :ets.insert(
      @table,
      {id, Map.merge(record, %{csrf: csrf, created_at: System.system_time(:second)})}
    )

    %{id: id, csrf: csrf}
  end

  @doc "Fetch a session by id, or `nil`."
  def get(nil), do: nil

  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, record}] -> record
      [] -> nil
    end
  end

  @doc "Drop a session (idempotent)."
  def delete(nil), do: :ok
  def delete(id) when is_binary(id), do: :ets.delete(@table, id) && :ok

  @doc "Stash a pending OAuth handoff before redirecting to GitHub; returns the state nonce."
  def put_pending(return_to) do
    state = token()
    :ets.insert(@table, {"pending:" <> state, %{return_to: return_to}})
    state
  end

  @doc "Consume a pending handoff by state nonce (single use); returns `return_to` or `nil`."
  def take_pending(nil), do: nil

  def take_pending(state) when is_binary(state) do
    key = "pending:" <> state

    case :ets.lookup(@table, key) do
      [{^key, %{return_to: return_to}}] ->
        :ets.delete(@table, key)
        return_to

      [] ->
        nil
    end
  end

  defp token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
