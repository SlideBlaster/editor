defmodule SbAuth.MintingKey do
  @moduledoc """
  The KMS-swappable signing seam (ADR 0010, `../../DESIGN.md`).

  The GitHub App private key is the crown jewel. Everything above this module
  (the App-JWT builder, the mint flow, the client) is blind to *where* the key
  lives — it only asks for a signature. That is the whole point: the KMS pass
  replaces the implementation and touches nothing else.

    * `SbAuth.MintingKey.Local` — reads the App `.pem` and RS256-signs in process
      (dev / self-host).
    * `SbAuth.MintingKey.Kms` (later) — sends the signing input's digest to a
      cloud KMS `asymmetricSign`; key material never leaves the KMS.

  The active implementation is chosen by config (`:sb_auth, SbAuth, :minting_key`).
  """
  @callback sign(signing_input :: binary()) :: {:ok, binary()} | {:error, term()}
  @callback key_id() :: String.t() | nil

  @doc "The configured implementation module."
  def impl do
    Application.get_env(:sb_auth, SbAuth)[:minting_key] || SbAuth.MintingKey.Local
  end

  @doc "RS256-sign `signing_input` with the App key via the active implementation."
  def sign(signing_input), do: impl().sign(signing_input)

  @doc "An opaque key identifier (for rotation / multi-key), or nil."
  def key_id, do: impl().key_id()
end

defmodule SbAuth.MintingKey.Local do
  @moduledoc """
  Local `MintingKey`: RS256-signs with the GitHub App `.pem` read from
  `APP_PRIVATE_KEY_PATH`. Dev / self-host only — the key sits on disk, not in a
  KMS. Swapped out wholesale by `SbAuth.MintingKey.Kms` in the hardening pass.
  """
  @behaviour SbAuth.MintingKey

  @impl true
  def sign(signing_input) do
    with {:ok, pem} <- read_key(),
         [entry | _] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry) do
      {:ok, :public_key.sign(signing_input, :sha256, key)}
    else
      [] -> {:error, :empty_pem}
      {:error, _} = err -> err
      other -> {:error, {:sign_failed, other}}
    end
  rescue
    e -> {:error, {:sign_raised, Exception.message(e)}}
  end

  @impl true
  def key_id, do: nil

  defp read_key do
    case Application.get_env(:sb_auth, SbAuth)[:app_private_key_path] do
      path when is_binary(path) ->
        if File.exists?(path), do: File.read(path), else: {:error, {:no_key_at, path}}

      _ ->
        {:error, :app_private_key_path_unset}
    end
  end
end
