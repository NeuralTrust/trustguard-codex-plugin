.PHONY: build dist test lint install-local uninstall-local release-plan

LOCAL_PLUGIN_DIR ?= $(HOME)/.codex/plugins/trustguard
VERSION ?= dev

build: ## Build the trustguard-codex hook binary into ./bin/
	@mkdir -p bin
	go build -buildvcs=false -trimpath -ldflags "-s -w" -o bin/trustguard-codex ./cli

dist: ## Cross-compile every release binary into ./dist/ (VERSION=X.Y.Z)
	@scripts/build-dist.sh $(VERSION)

test: ## Run the test suite
	go test -race ./cli/
	sh tests/bootstrap-hook.sh

lint: ## Vet the sources
	go vet ./cli/

release-plan: ## Print what the Release workflow would do (mode + version)
	@python3 scripts/release.py plan

# Copies the plugin and writes ~/.codex/hooks.json with absolute paths.
# Codex runs hooks with the session cwd, so relative paths are unreliable.
install-local: build ## Install plugin + wire user hooks for local testing
	@rm -rf "$(LOCAL_PLUGIN_DIR)"
	@mkdir -p "$(LOCAL_PLUGIN_DIR)"
	@cp -R trustguard/. "$(LOCAL_PLUGIN_DIR)/"
	@mkdir -p "$(HOME)/.trustguard/bin"
	@cp bin/trustguard-codex "$(HOME)/.trustguard/bin/trustguard-codex"
	@chmod 0755 "$(HOME)/.trustguard/bin/trustguard-codex" "$(LOCAL_PLUGIN_DIR)/hooks/trustguard-hook.sh"
	@python3 scripts/install-hooks.py "$(LOCAL_PLUGIN_DIR)"
	@echo "installed $(LOCAL_PLUGIN_DIR) — open Codex and run /hooks to trust TrustGuard"

uninstall-local: ## Remove the locally installed plugin and hooks.json we wrote
	@rm -rf "$(LOCAL_PLUGIN_DIR)"
	@rm -f "$(HOME)/.codex/hooks.json"
	@echo "removed local TrustGuard Codex install"
