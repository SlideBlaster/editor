defmodule SbAuth.AppJwt do
  @moduledoc """
  Builds and signs the short-lived GitHub App JWT used to authenticate *as the
  App* when minting installation tokens (ADR 0010).

  RS256, `iss` = the App's client id (GitHub's current recommendation; the App id
  also works), `iat` backdated 30s for clock skew, `exp` at +9min (GitHub's ceiling
  is 10min). The signature is produced through the `SbAuth.MintingKey` seam, so
  this module never touches key material.
  """
  alias SbAuth.MintingKey

  @doc "Return `{:ok, jwt}` for App authentication, or `{:error, reason}`."
  def generate do
    cfg = Application.get_env(:sb_auth, SbAuth)
    iss = cfg[:github_client_id] || cfg[:github_app_id]

    if is_nil(iss) do
      {:error, :app_identity_unset}
    else
      now = System.system_time(:second)
      header = %{"alg" => "RS256", "typ" => "JWT"}
      claims = %{"iss" => iss, "iat" => now - 30, "exp" => now + 540}
      signing_input = b64(header) <> "." <> b64(claims)

      case MintingKey.sign(signing_input) do
        {:ok, sig} -> {:ok, signing_input <> "." <> Base.url_encode64(sig, padding: false)}
        {:error, _} = err -> err
      end
    end
  end

  defp b64(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
