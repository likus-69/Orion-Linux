# Orion Linux top-level Makefile
#
# Common targets:
#   make help            Show this help
#   make prepare         Install host build deps (Docker, qemu-user-static)
#
# v0.1 fast-path (recommended — uses Debian bootstrap, builds in ~20 min):
#   make build-quick             Build the rootfs tarball + ISO (ARCH=x86_64)
#   make build-quick ARCH=aarch64  Same, for ARM64 (under QEMU)
#
# v0.2+ full LFS-from-scratch path (slow, ~6-10 hours, may be incomplete):
#   make build                   Build the full LFS rootfs
#   make build ARCH=aarch64        Build for ARM64 (uses QEMU emulation)
#
#   make iso                     Build the bootable netinst ISO from a finished rootfs
#   make img                     Build a flashable disk image (.img)
#   make clean                   Remove build artifacts (keeps Docker cache)
#   make distclean               Remove everything including Docker cache
#   make lint                    Run shellcheck on all scripts
#   make test                    Run orion-pkg unit tests
#   make release VERSION=0.1.0  Tag a release and trigger CI image builds
#
# All targets accept ARCH=x86_64|aarch64 (default: host arch).

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ARCH ?= $(shell uname -m)
ifeq ($(ARCH),x86_64)
  TARGETARCH := amd64
  PLATFORM_FLAG := --platform linux/amd64
else ifeq ($(ARCH),aarch64)
  TARGETARCH := arm64
  PLATFORM_FLAG := --platform linux/arm64
else
  $(error Unsupported ARCH '$(ARCH)'. Use x86_64 or aarch64.)
endif

WORKDIR := $(CURDIR)
BUILD_DIR := $(WORKDIR)/build
OUT_DIR := $(WORKDIR)/out

# Discover version from git tag, fall back to "dev"
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

DOCKER ?= docker

# Common Docker build args; $(DOCKERFILE) and $(IMAGE_TAG) are set per-target
define docker_build
$(DOCKER) build --no-cache=false \
  --build-arg ARCH=$(ARCH) \
  --build-arg VERSION=$(VERSION) \
  --build-arg TARGETARCH=$(TARGETARCH) \
  --file $(1) \
  --tag $(2) \
  --progress=plain \
  $(PLATFORM_FLAG) .
endef

.PHONY: help prepare build build-quick iso img clean distclean lint test release

help:  ## Show this help
	@echo "Orion Linux build system"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables:"
	@echo "  ARCH=x86_64|aarch64   (default: host arch, currently $(ARCH))"
	@echo "  VERSION=x.y.z         (default: git describe, currently $(VERSION))"

prepare:  ## Install host build deps (Docker, qemu-user-static, qemu-utils)
	@echo "==> Installing host build dependencies"
	@command -v docker >/dev/null 2>&1 || { \
	        echo "ERROR: docker not found. Install Docker Engine first." >&2; exit 1; }
	@sudo apt-get update -qq
	@sudo apt-get install -y --no-install-recommends \
	        qemu-user-static qemu-utils ovmf xorriso mtools dosfstools
	@docker run --rm --privileged multiarch/qemu-user-static --reset -p yes || \
	        echo "QEMU binfmt already registered (or running on native ARM)"

build:  ## [v0.2+] Build the full LFS-from-scratch rootfs tarball (slow, ~6-10 hr)
	@echo "==> Building Orion Linux rootfs (LFS path) for $(ARCH) (version $(VERSION))"
	@mkdir -p $(BUILD_DIR) $(OUT_DIR)
	@echo "    Building Docker image: orion-linux:lfs-$(ARCH)-$(VERSION)"
	$(call docker_build,images/Dockerfile.$(TARGETARCH),orion-linux:lfs-$(ARCH)-$(VERSION))
	@echo "    Extracting rootfs tarball from image"
	@container_id=$$(docker create orion-linux:lfs-$(ARCH)-$(VERSION)); \
	        docker cp $$container_id:/out/. $(OUT_DIR)/; \
	        docker rm $$container_id >/dev/null
	@echo "==> Done. Output: $(OUT_DIR)/orion-rootfs-$(ARCH)-$(VERSION).tar.xz"

build-quick:  ## [v0.1] Build the rootfs + ISO via Debian bootstrap (fast, ~20 min)
	@echo "==> Building Orion Linux v0.1 rootfs (bootstrap path) for $(ARCH) (version $(VERSION))"
	@mkdir -p $(BUILD_DIR) $(OUT_DIR)
	@echo "    Building Docker image: orion-linux:bootstrap-$(ARCH)-$(VERSION)"
	$(call docker_build,images/Dockerfile.bootstrap,orion-linux:bootstrap-$(ARCH)-$(VERSION))
	@echo "    Extracting artifacts from image"
	@container_id=$$(docker create orion-linux:bootstrap-$(ARCH)-$(VERSION)); \
	        docker cp $$container_id:/out/. $(OUT_DIR)/; \
	        docker rm $$container_id >/dev/null
	@echo "==> Done. Artifacts in: $(OUT_DIR)/"
	@ls -la $(OUT_DIR)/ || true

iso:  ## Build bootable netinst ISO from a finished rootfs
	@echo "==> Building netinst ISO for $(ARCH)"
	@test -f $(OUT_DIR)/orion-rootfs-$(ARCH)-$(VERSION).tar.xz || \
	        { echo "ERROR: rootfs not found. Run 'make build' first." >&2; exit 1; }
	@scripts/08-release-artifacts.sh iso \
	        --arch $(ARCH) \
	        --version $(VERSION) \
	        --rootfs $(OUT_DIR)/orion-rootfs-$(ARCH)-$(VERSION).tar.xz \
	        --out $(OUT_DIR)
	@echo "==> ISO: $(OUT_DIR)/Orion-Linux-$(VERSION)-$(ARCH)-netinst.iso"

img:  ## Build flashable disk image (.img) for ARM SBCs
	@echo "==> Building flashable disk image for $(ARCH)"
	@scripts/08-release-artifacts.sh img \
	        --arch $(ARCH) \
	        --version $(VERSION) \
	        --rootfs $(OUT_DIR)/orion-rootfs-$(ARCH)-$(VERSION).tar.xz \
	        --out $(OUT_DIR)
	@echo "==> IMG: $(OUT_DIR)/Orion-Linux-$(VERSION)-$(ARCH).img"

clean:  ## Remove build artifacts (keeps Docker cache)
	@echo "==> Cleaning local build artifacts"
	@rm -rf $(BUILD_DIR) $(OUT_DIR) build/rootfs
	@find packages -type d -name 'pkg' -exec rm -rf {} + 2>/dev/null || true

distclean: clean  ## Remove everything including Docker cache
	@echo "==> Wiping Docker build cache (this is slow)"
	@$(DOCKER) builder prune -f --all || true
	@rm -rf $(WORKDIR)/.docker-cache $(WORKDIR)/.qemu

lint:  ## Run shellcheck on all shell scripts
	@echo "==> Running shellcheck"
	@command -v shellcheck >/dev/null 2>&1 || \
	        { echo "shellcheck not installed; install with: apt install shellcheck" >&2; exit 1; }
	@shellcheck -x \
	        scripts/*.sh scripts/lib/*.sh \
	        orion-pkg/orion-pkg \
	        installer/orion-installer installer/modules/*.sh \
	        images/entrypoint.sh \
	        || exit 1

test:  ## Run orion-pkg unit tests
	@echo "==> Running orion-pkg tests"
	@bash orion-pkg/tests/test_basic.sh

release:  ## Tag a release and trigger CI image builds (VERSION=x.y.z required)
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=0.1.0" >&2; exit 1; }
	@echo "==> Tagging release $(VERSION)"
	@git tag -a v$(VERSION) -m "Orion Linux $(VERSION)"
	@git push origin v$(VERSION)
	@echo "==> Pushed tag v$(VERSION). Watch CI at:"
	@echo "    https://github.com/likus-69/Orion-Linux/actions"
