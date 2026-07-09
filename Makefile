# Local mirror of the CI checks so changes can be verified before pushing.
# The GitHub workflows (.github/workflows/*.yml) call these same targets, so
# "green locally" == "green in CI". Requires pnpm (repo packageManager) + make.
#
#   make          same as `make check` (the exact CI gate)
#   make format   auto-fix formatting (prettier --write)
#   make build    fetch the latexml engine + build the web shell (Pages artifact)

.DEFAULT_GOAL := check
.PHONY: install format format-check typecheck test check engine build

install:
	pnpm install --frozen-lockfile

format:
	pnpm format

format-check:
	pnpm format:check

typecheck:
	pnpm typecheck

test:
	pnpm test

check: format-check typecheck test

# Fetch the prebuilt LaTeXML WASM runtime from the engine-v1 GitHub Release
# (idempotent, sha256-verified). Only the web-shell build consumes it.
engine:
	bash packages/adapters-shared/src/compile/engine/fetch-dist.sh

build: engine
	pnpm --filter @slideblaster/web-shell build
