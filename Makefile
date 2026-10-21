PLATFORM ?= darwin
ARCH ?= arm64
TARGET ?= macos
SLUG = $(if $(filter macos,$(TARGET)),$(ARCH),$(ARCH)-$(TARGET))

.PHONY: build package lint bump help
build: ## Build all deps for ARCH and TARGET (macos|ios|ios-simulator) into out/$(SLUG)/pool (skips already-built)
	PLATFORM=$(PLATFORM) TARGET=$(TARGET) ./scripts/build.sh $(ARCH)

package: ## Package every built target under out/ into dist/build.tar.gz (requires: make build)
	PLATFORM=$(PLATFORM) ./scripts/package.sh $(ARCH) out dist

lint: ## Validate deps.toml
	PLATFORM=$(PLATFORM) ./scripts/plan.sh --check

bump: ## make bump NAME=openssl VERSION=3.6.5 [SHA256=...], or NAME=libplacebo [REF=v7.360.1] for a git pin
	PLATFORM=$(PLATFORM) ./scripts/bump.sh $(if $(VERSION),$(NAME) $(VERSION) $(SHA256),--git $(NAME) $(REF))

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
