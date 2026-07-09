# Local mirror of the CI checks so changes can be verified before pushing.
# The GitHub workflows (.github/workflows/*.yml) call these same targets, so
# "green locally" == "green in CI". Requires pnpm (repo packageManager) + make.
#
#   make          same as `make check` (the exact CI gate)
#   make format   auto-fix formatting (prettier --write)
#   make build    build the web shell (the Pages deploy artifact)

.DEFAULT_GOAL := check
.PHONY: install format format-check typecheck test check build

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

build:
	pnpm --filter @slideblaster/web-shell build
