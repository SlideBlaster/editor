.DEFAULT_GOAL := dev

PORT ?= 4173
PROJECT ?= cabal.project.native

.PHONY: dev lint test check metadata-validate session-validate \
        release-version-check release-verify

dev: lint
	./scripts/build-wasm.sh
	./scripts/serve-web.sh "$(PORT)"

# Mechanical enforcement of the totality rules in STYLE.md, plus a syntax check
# of the browser host. Both are cheap enough to run before every build.
lint:
	./scripts/lint-totality.py
	@for f in $$(find hosts/web/src -name '*.js'); do node --check "$$f" || exit 1; done
	@printf 'host syntax: clean\n'

test:
	cabal --project-file="$(PROJECT)" test all --test-show-details=direct

check: lint test

metadata-validate session-validate:
	./scripts/session/validate.sh

release-version-check:
	./scripts/release/check-versions.sh

release-verify:
	./scripts/release/verify.sh
