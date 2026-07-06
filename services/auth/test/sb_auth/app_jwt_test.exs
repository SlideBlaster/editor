defmodule SbAuth.AppJwtTest do
  @moduledoc """
  Proves the homegrown App-JWT path end to end: a real RSA key on disk, signed
  through the `MintingKey.Local` seam, produces a structurally-valid RS256 JWT
  whose signature verifies against the public key. This is the crypto GitHub
  will check when we authenticate as the App.
  """
  use ExUnit.Case, async: false

  setup do
    # A throwaway RSA keypair, written as a PKCS#1 PEM (the format GitHub hands out).
    private = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private)])
    path = Path.join(System.tmp_dir!(), "sb_test_app_#{System.unique_integer([:positive])}.pem")
    File.write!(path, pem)

    prev = Application.get_env(:sb_auth, SbAuth)

    Application.put_env(:sb_auth, SbAuth,
      github_client_id: "Iv1.testclientid",
      app_private_key_path: path,
      minting_key: SbAuth.MintingKey.Local
    )

    on_exit(fn ->
      File.rm(path)
      if prev, do: Application.put_env(:sb_auth, SbAuth, prev)
    end)

    # RSAPrivateKey record: {:RSAPrivateKey, version, modulus, publicExponent, ...}
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{public: public}
  end

  test "generate/0 returns a valid, verifiable RS256 JWT", %{public: public} do
    assert {:ok, jwt} = SbAuth.AppJwt.generate()

    [h64, p64, s64] = String.split(jwt, ".")
    header = h64 |> b64!() |> Jason.decode!()
    claims = p64 |> b64!() |> Jason.decode!()

    assert header["alg"] == "RS256"
    assert header["typ"] == "JWT"
    assert claims["iss"] == "Iv1.testclientid"
    assert claims["exp"] > claims["iat"]
    # GitHub rejects JWTs whose lifetime exceeds 10 minutes.
    assert claims["exp"] - claims["iat"] <= 600

    signing_input = h64 <> "." <> p64
    signature = b64!(s64)
    assert :public_key.verify(signing_input, :sha256, signature, public)
  end

  test "sign fails cleanly when the key path is missing" do
    Application.put_env(:sb_auth, SbAuth,
      github_client_id: "Iv1.testclientid",
      app_private_key_path: "/no/such/key.pem",
      minting_key: SbAuth.MintingKey.Local
    )

    assert {:error, _} = SbAuth.AppJwt.generate()
  end

  defp b64!(s), do: Base.url_decode64!(s, padding: false)
end
