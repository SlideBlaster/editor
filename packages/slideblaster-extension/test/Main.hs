{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Contract tests for the extension broker's pure core.
--
-- Covers SHA-256 vectors, base64, strict manifest validation (including the
-- design 4.2 examples), envelope round trips, fingerprint stability and
-- sensitivity, cache layout, the TikZ request builder, the @\\input@ closure,
-- and TeX log to source line mapping.
module Main (main) where

import SlideBlaster.Extension

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy (toStrict)
import Data.List.NonEmpty (NonEmpty (..))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Exit (exitFailure)

data Check = Check String Bool

check :: String -> Bool -> Check
check = Check

main :: IO ()
main = do
  closure <- closureChecks
  let failures = [name | Check name False <- allChecks <> closure]
      total = length (allChecks <> closure)
  mapM_ (putStrLn . ("FAIL: " <>)) failures
  putStrLn (show (total - length failures) <> "/" <> show total <> " checks passed")
  if null failures then pure () else exitFailure

allChecks :: [Check]
allChecks = shaChecks <> base64Checks <> manifestChecks <> envelopeChecks <> fingerprintChecks <> tikzChecks <> logChecks

hexOf :: ByteString -> String
hexOf = Char8.unpack . sha256Hex

shaChecks :: [Check]
shaChecks =
  [ check "sha256 empty" (hexOf "" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  , check "sha256 abc" (hexOf "abc" == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  , check "sha256 two-block message"
      (hexOf "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
         == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  , check "sha256 55 bytes (padding edge)" (hexOf (Char8.replicate 55 'a') == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
  , check "sha256 56 bytes (padding edge)" (hexOf (Char8.replicate 56 'a') == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
  , check "sha256 64 bytes" (hexOf (Char8.replicate 64 'a') == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
  , check "sha256 million a" (hexOf (Char8.replicate 1000000 'a') == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  ]

base64Checks :: [Check]
base64Checks =
  [ check "base64 vectors"
      ( map encodeBase64 ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
          == ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]
      )
  , check "base64 decode inverse" (all (\s -> decodeBase64 (encodeBase64 s) == Just s) ["", "f", "fo", "foo", "\0\255\128xyz"])
  , check "base64 rejects bad length" (decodeBase64 "Zm9" == Nothing)
  , check "base64 rejects bad char" (decodeBase64 "Zm9*" == Nothing)
  , check "base64 rejects non-canonical" (decodeBase64 "Zh==" == Nothing)
  , check "base64 rejects mid padding" (decodeBase64 "Zg==Zg==" == Nothing)
  ]

texManifestJson :: ByteString
texManifestJson =
  "{ \"id\": \"sb.tex\", \"version\": \"0.2.0\",\
  \  \"provides\": [{ \"slot\": \"block.render\", \"kinds\": [\"tikz\", \"tex\"], \"output\": \"image/svg+xml\" }],\
  \  \"transport\": { \"kind\": \"builtin-native\" },\
  \  \"needs\": [{ \"tool\": \"latex\" }, { \"tool\": \"dvisvgm\" }],\
  \  \"permissions\": [\"exec:tex\", \"fs:project:read\"],\
  \  \"limits\": { \"timeoutMs\": 60000, \"maxBytes\": 8388608 } }"

graphvizJson :: ByteString
graphvizJson =
  "{ \"id\": \"user.graphviz\", \"version\": \"1.0.0\",\
  \  \"provides\": [{ \"slot\": \"block.render\", \"kinds\": [\"dot\"], \"output\": \"image/svg+xml\" }],\
  \  \"transport\": { \"kind\": \"stdio-json\", \"argv\": [\"dot\", \"-Tsvg\"], \"stdin\": \"body\", \"stdout\": \"artifact\" },\
  \  \"permissions\": [\"exec:dot\"], \"limits\": { \"timeoutMs\": 10000, \"maxBytes\": 4194304 } }"

rejects :: Text -> ByteString -> Bool
rejects path bytes = case parseManifest bytes of
  Left err -> manifestErrorPath err == path
  Right _ -> False

manifestChecks :: [Check]
manifestChecks =
  [ check "design 4.2 sb.tex manifest equals the built-in" (parseManifest texManifestJson == Right builtinTexManifest)
  , check "graphviz manifest parses as stdio-json"
      (fmap manifestTransport (parseManifest graphvizJson) == Right (StdioJson (StdioSpec ("dot" :| ["-Tsvg"]))))
  , check "manifest round trips" (parseManifest (manifestToJson builtinTexManifest) == Right builtinTexManifest)
  , check "unknown top-level field rejected" (rejects "colour" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"},\"colour\":1}")
  , check "unknown provides field rejected" (rejects "provides[0].extra" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\",\"extra\":1}],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "unknown transport field rejected" (rejects "transport.shell" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\",\"shell\":true}}")
  , check "unknown limits field rejected" (rejects "limits.cpu" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"},\"limits\":{\"cpu\":1}}")
  , check "unknown slot rejected" (rejects "provides[0].slot" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"nope\"}],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "block.render needs kinds" (rejects "provides[0].kinds" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"block.render\",\"output\":\"x/y\"}],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "block.render needs output" (rejects "provides[0].output" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"block.render\",\"kinds\":[\"k\"]}],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "block.edit is interface-only but parses" (either (const False) (const True) (parseManifest "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"block.edit\",\"kinds\":[\"tikz\"]}],\"transport\":{\"kind\":\"builtin-host\"}}"))
  , check "empty provides rejected" (rejects "provides" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "empty argv rejected" (rejects "transport.argv" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"stdio-json\",\"argv\":[]}}")
  , check "stdin other than body rejected" (rejects "transport.stdin" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"stdio-json\",\"argv\":[\"x\"],\"stdin\":\"file\"}}")
  , check "bad id rejected" (rejects "id" "{\"id\":\"../x\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "tool path rejected" (rejects "needs[0].tool" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"},\"needs\":[{\"tool\":\"/bin/sh\"}]}")
  , check "non-positive limit rejected" (rejects "limits.timeoutMs" "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"},\"limits\":{\"timeoutMs\":0}}")
  , check "missing field named" (rejects "version" "{\"id\":\"a\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"}}")
  , check "invalid JSON rejected" (rejects "" "{")
  , check "limits default" (fmap manifestLimits (parseManifest "{\"id\":\"a\",\"version\":\"1\",\"provides\":[{\"slot\":\"capability\"}],\"transport\":{\"kind\":\"builtin-host\"}}") == Right defaultLimits)
  , check "slot names round trip" (all (\s -> parseSlot (slotName s) == Just s) allSlots && length allSlots == 6)
  , check "only block.render is dispatched" ([s | s <- allSlots, slotStatus s == Dispatched] == [BlockRender])
  , check "registry: earlier manifest shadows" shadowing
  ]
  where
    shadowing = case (parseManifest graphvizJson, parseManifest (Char8.pack (replaceId (Char8.unpack graphvizJson)))) of
      (Right a, Right b) ->
        fmap manifestId (lookupProvider BlockRender "dot" (mkRegistry [b, a])) == Just "user.other"
          && fmap manifestId (lookupProvider BlockRender "dot" (mkRegistry [builtinTexManifest, a])) == Just "user.graphviz"
          && lookupProvider BlockRender "nope" (mkRegistry [a, b]) == Nothing
      _ -> False
    replaceId = Text.unpack . Text.replace "user.graphviz" "user.other" . Text.pack

sampleRequest :: BlockRequest
sampleRequest =
  (emptyBlockRequest "tikz" "\\draw (0,0) -- (1,1);")
    { requestPreamble = "\\usepackage{pifont}"
    , requestPalette = [PaletteColour "palCoral" "FF595E"]
    , requestWidth = Just 960
    , requestInputs = [ResolvedInput "b.tex" "bb", ResolvedInput "a.tex" "aa"]
    , requestLineMap = Just (LineMap "figures/a.tikz" 1)
    }

envelopeFor :: BlockRequest -> RenderEnvelope
envelopeFor req =
  RenderEnvelope (Ticket "t-1") (Just (requestFingerprint texId req)) (Just 5000) req

texId :: ProviderIdentity
texId = providerIdentity builtinTexManifest

envelopeChecks :: [Check]
envelopeChecks =
  [ check "envelope round trips through JSON" $
      case Aeson.decodeStrict (toStrict (Aeson.encode (Aeson.object (encodeRenderEnvelope (envelopeFor sampleRequest))))) of
        Just (Aeson.Object o) -> fmap normalise (decodeRenderEnvelope o) == Right (normalise (envelopeFor sampleRequest))
        _ -> False
  , check "envelope rejects wrong slot" $
      decodeObject "{\"ticket\":\"t\",\"slot\":\"capability\",\"kind\":\"tikz\",\"input\":{\"body\":\"x\"}}" `failsWith` "slot"
  , check "envelope requires ticket" $
      decodeObject "{\"kind\":\"tikz\",\"input\":{\"body\":\"x\"}}" `failsWith` "ticket"
  , check "envelope requires body" $
      decodeObject "{\"ticket\":\"t\",\"kind\":\"tikz\",\"input\":{}}" `failsWith` "input.body"
  , check "envelope rejects bad fingerprint" $
      decodeObject "{\"ticket\":\"t\",\"kind\":\"tikz\",\"fingerprint\":\"XYZ\",\"input\":{\"body\":\"x\"}}" `failsWith` "fingerprint"
  , check "envelope rejects bad base64 input" $
      decodeObject "{\"ticket\":\"t\",\"kind\":\"tikz\",\"input\":{\"body\":\"x\",\"inputs\":[{\"path\":\"a\",\"contentBase64\":\"!\"}]}}" `failsWith` "input.inputs[].contentBase64"
  , check "result round trip: rendered" (roundTripResult renderedResult)
  , check "result round trip: failed" (roundTripResult failedResult)
  , check "result round trip: absent" (roundTripResult absentResult)
  , check "binary artifact uses base64" $
      roundTripResult renderedResult {resultOutcome = Rendered ((artifactOf renderedResult) {artifactMime = "image/png", artifactBytes = "\0\1\2\255"})}
  , check "echo check accepts exact ticket+fingerprint" (acceptsResult (Ticket "t-1") fp renderedResult)
  , check "echo check rejects other ticket" (not (acceptsResult (Ticket "t-2") fp renderedResult))
  , check "echo check rejects other fingerprint" (not (acceptsResult (Ticket "t-1") (requestFingerprint texId (emptyBlockRequest "tikz" "x")) renderedResult))
  ]
  where
    normalise e = e
    fp = requestFingerprint texId sampleRequest
    artifactOf r = case resultOutcome r of
      Rendered a -> a
      _ -> Artifact "" "" (Provenance "" "" False 0)
    renderedResult =
      RenderResult (Ticket "t-1") fp
        (Rendered (Artifact "image/svg+xml" "<svg>\233</svg>" (Provenance "sb.tex" "0.2.0" True 12))) []
    failedResult =
      RenderResult (Ticket "t-1") fp Failed
        [Diagnostic SeverityError "tex.error" "Undefined control sequence" (Just 23) (Just 14) (Just "figures/a.tikz")]
    absentResult =
      let a = ToolMissing "sb.tex" "dvisvgm"
       in RenderResult (Ticket "t-1") fp (Absent a) [absenceDiagnostic a]
    roundTripResult r = case Aeson.decodeStrict (toStrict (Aeson.encode (Aeson.object (encodeRenderResult r)))) of
      Just (Aeson.Object o) -> decodeRenderResult o == Right r
      _ -> False
    decodeObject bytes = case Aeson.decodeStrict bytes of
      Just (Aeson.Object o) -> decodeRenderEnvelope o
      _ -> Left (EnvelopeError "json" "bad")
    failsWith result field = case result of
      Left err -> envelopeErrorField err == field
      Right _ -> False

fingerprintChecks :: [Check]
fingerprintChecks =
  [ check "fingerprint is 64 lower-case hex" (Text.length (fingerprintText base) == 64 && mkFingerprint (fingerprintText base) == Just base)
  , check "fingerprint rejects upper case" (mkFingerprint (Text.toUpper (fingerprintText base)) == Nothing)
  , check "fingerprint stable" (base == requestFingerprint texId sampleRequest)
  , check "fingerprint ignores input order" (base == requestFingerprint texId sampleRequest {requestInputs = reverse (requestInputs sampleRequest)})
  , check "fingerprint ignores line map" (base == requestFingerprint texId sampleRequest {requestLineMap = Nothing})
  , check "fingerprint: body" (differs sampleRequest {requestBody = "x"})
  , check "fingerprint: preamble" (differs sampleRequest {requestPreamble = ""})
  , check "fingerprint: palette" (differs sampleRequest {requestPalette = []})
  , check "fingerprint: width" (differs sampleRequest {requestWidth = Just 961})
  , check "fingerprint: input bytes" (differs sampleRequest {requestInputs = [ResolvedInput "a.tex" "XX", ResolvedInput "b.tex" "bb"]})
  , check "fingerprint: kind" (differs sampleRequest {requestKind = "tex"})
  , check "fingerprint: provider version" (base /= requestFingerprint texId {providerVersion = "0.2.1"} sampleRequest)
  , check "fingerprint: provider id" (base /= requestFingerprint texId {providerId = "other"} sampleRequest)
  , check "fingerprint: field boundaries are unambiguous"
      (requestFingerprint texId (emptyBlockRequest "ab" "c") /= requestFingerprint texId (emptyBlockRequest "a" "bc"))
  , check "cache layout" (cacheSegments texId base == [".slideblaster", "cache", "sb.tex", fingerprintText base])
  , check "absence is typed and labelled"
      ( absenceCode (ToolMissing "sb.tex" "dvisvgm") == "tool_missing"
          && absencePlaceholderLabel "tikz" (ToolMissing "sb.tex" "dvisvgm") == "tikz figure (dvisvgm not installed)"
      )
  ]
  where
    base = requestFingerprint texId sampleRequest
    differs r = base /= requestFingerprint texId r

tikzChecks :: [Check]
tikzChecks =
  [ check "wrapper uses standalone class" (head' docLines == "\\documentclass[tikz,border=1pt]{standalone}")
  , check "bare body is wrapped in tikzpicture" ("\\begin{tikzpicture}" `elem` docLines && "\\end{tikzpicture}" `elem` docLines)
  , check "full tikzpicture is not double wrapped" (length (filter (== "\\begin{tikzpicture}") (Text.lines (buildTikzDocument (emptyBlockRequest "tikz" "\\begin{tikzpicture}\n\\end{tikzpicture}")))) == 1)
  , check "deck preamble present and before document" (indexOf "\\usepackage{pifont}" < indexOf "\\begin{document}")
  , check "preamble precedes inferred libraries" (indexOf "\\usepackage{pifont}" < indexOf' "\\usetikzlibrary")
  , check "palette emitted as definecolor" ("\\definecolor{palCoral}{HTML}{FF595E}" `elem` docLines)
  , check "invalid palette entries dropped" ("definecolor" `Text.isInfixOf` doc && not ("evil" `Text.isInfixOf` buildTikzDocument sampleRequest {requestPalette = [PaletteColour "evil}\\x" "FF595E", PaletteColour "ok" "GG0000"]}))
  , check "default libraries inferred" ("positioning" `elem` inferLibraries "")
  , check "named library kept" ("mylib" `elem` inferLibraries "\\usetikzlibrary{mylib, calc}")
  , check "\\ding marker adds pifont" (lookup "pifont" (inferPackages "\\ding{51}") /= Nothing)
  , check "\\dingbats does not add pifont" (lookup "pifont" (inferPackages "\\dingbats") == Nothing)
  , check "zi4 marker adds inconsolata" (lookup "inconsolata" (inferPackages "\\fontfamily{zi4}") /= Nothing)
  , check "tdplot marker adds 3d" ("3d" `elem` inferLibraries "\\tdplotsetmaincoords{70}{110}")
  , check "usepackage options kept" (lookup "foo" (inferPackages "\\usepackage[bar=1]{foo}") == Just "\\usepackage[bar=1]{foo}")
  , check "package declared by deck preamble not duplicated" (length (filter ("pifont" `Text.isInfixOf`) docLines) == 1)
  , check "body usepackage is hoisted, not left in body" hoisted
  , check "markers precede every body line" markersOk
  , check "marker maps TeX line to body line (bare body)" (mapTexLine markerDoc (lineOfBody markerDoc "\\bad") == Just 3)
  , check "marker maps TeX line to body line (full tikzpicture)" (mapTexLine markerDoc2 (lineOfBody markerDoc2 "\\bad") == Just 3)
  , check "scanInputs braces and bare" (scanInputs "\\input{a/b}\n\\input c.tex\n\\include{d} % \\input{ignored}" == ["a/b", "c.tex", "d"])
  , check "scanInputs ignores \\inputbox" (scanInputs "\\node[inputbox] {x}" == [])
  ]
  where
    hoistedLines = Text.lines (buildTikzDocument (emptyBlockRequest "tikz" "\\usepackage[bar]{foo}\n\\draw (0,0);"))
    hoisted =
      length (filter (== "\\usepackage[bar]{foo}") hoistedLines) == 1
        && length (takeWhile (/= "\\usepackage[bar]{foo}") hoistedLines) < length (takeWhile (/= "\\begin{document}") hoistedLines)
    doc = buildTikzDocument sampleRequest
    docLines = Text.lines doc
    head' ls = case ls of
      l : _ -> l
      [] -> ""
    indexOf needle = length (takeWhile (/= needle) docLines)
    indexOf' prefix = length (takeWhile (not . Text.isPrefixOf prefix) docLines)
    markerDoc = buildTikzDocument (emptyBlockRequest "tikz" "\\draw (0,0);\n\\draw (1,1);\n\\bad;")
    markerDoc2 = buildTikzDocument (emptyBlockRequest "tikz" "\\begin{tikzpicture}\n\\draw (0,0);\n\\bad;\n\\end{tikzpicture}")
    lineOfBody d needle = length (takeWhile (not . (needle `Text.isPrefixOf`)) (Text.lines d)) + 1
    markersOk =
      let ls = Text.lines (buildTikzDocument (emptyBlockRequest "tikz" "a\nb\nc"))
          bodyStart = length (takeWhile (/= "\\begin{document}") ls) + 1
          body = take 8 (drop bodyStart ls)
       in all (\(m, l) -> markerPrefix `Text.isPrefixOf` m && not (markerPrefix `Text.isPrefixOf` l)) (pairs (drop 2 body))
    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _ = []

logChecks :: [Check]
logChecks =
  [ check "log: first bang line and l.N" $
      parseTexLog "This is pdfTeX\n(./f.tex)\n! Undefined control sequence.\nl.23 \\foo\n \n? \n! Emergency stop.\nl.99 x" == Just (TexError "Undefined control sequence" (Just 23))
  , check "log: bang without line" (parseTexLog "! LaTeX Error: File `x.sty' not found.\n\nType X to quit" == Just (TexError "LaTeX Error: File `x.sty' not found" Nothing))
  , check "log: clean log" (parseTexLog "Output written on f.dvi" == Nothing)
  ]

closureChecks :: IO [Check]
closureChecks = do
  calls <- newIORef (0 :: Int)
  let files =
        [ ("figures/part.tex", "\\input{figures/deep}")
        , ("figures/deep.tex", "deep \\input{figures/part}")
        , ("shared.tex", "shared")
        , ("figures/local.tex", "local")
        ]
      reader path = do
        modifyIORef calls (+ 1)
        pure (Encoding.encodeUtf8 <$> lookup path files)
  (resolved, unresolved) <-
    resolveInputClosure reader "figures" "\\input{figures/part}\n\\input{shared}\n\\input{local}\n\\input{missing}\n\\input{../secret}\n\\input{/etc/passwd}"
  n <- readIORef calls
  pure
    [ check "closure resolves transitive inputs, cycle terminates"
        (map inputPath resolved == ["figures/part.tex", "shared.tex", "local.tex", "figures/deep.tex"])
    , check "closure stores bytes" (lookup "shared.tex" [(inputPath r, inputBytes r) | r <- resolved] == Just "shared")
    , check "closure leaves missing and unsafe unresolved" (unresolved == ["missing", "../secret", "/etc/passwd"])
    , check "closure never reads unsafe paths" (n < 20)
    ]
