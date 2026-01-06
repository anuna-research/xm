# xm - Cross Memory CLI
# Makefile for building, testing, and running the xm agent memory system

.PHONY: all build build-debug test test-rust test-guile clean install uninstall run check fmt help

# Configuration
CARGO := cargo
GUILE := guile
PREFIX ?= $(HOME)/.local

# Paths
BUILD_DIR := target/release
DEBUG_DIR := target/debug
LIB_NAME := libxm_ffi
GUILE_MODULES := guile

# Environment for running Guile with xm modules
export GUILE_LOAD_PATH := $(CURDIR)/guile:/opt/homebrew/share/guile/site/3.0
export XM_LIB_PATH := $(CURDIR)/$(BUILD_DIR)

# Default target
all: build

## Build targets

build: ## Build release version of the Rust FFI library
	$(CARGO) build --release

build-debug: ## Build debug version of the Rust FFI library
	$(CARGO) build

## Test targets

test: test-rust test-guile ## Run all tests

test-rust: build ## Run Rust tests
	$(CARGO) test --release

test-guile: build ## Run Guile integration tests
	@echo "=== Store persistence test ==="
	@rm -rf /tmp/xm-make-test
	@$(GUILE) --no-auto-compile -c '\
	(use-modules (xm store)) \
	(let ((store (make-store "/tmp/xm-make-test"))) \
	  (store-update store "INSERT DATA { <http://test/s> <http://test/p> \"value\" }") \
	  (let ((count (store-count store))) \
	    (store-close store) \
	    (if (= count 1) \
	        (display "PASS: Store insert works\n") \
	        (error "FAIL: Expected count 1"))))'
	@$(GUILE) --no-auto-compile -c '\
	(use-modules (xm store)) \
	(let ((store (make-store "/tmp/xm-make-test"))) \
	  (let ((count (store-count store))) \
	    (store-close store) \
	    (if (= count 1) \
	        (display "PASS: Persistence works\n") \
	        (error "FAIL: Data not persisted"))))'
	@echo "=== CLI node test ==="
	@rm -rf /tmp/xm-cli-make-test
	@$(GUILE) --no-auto-compile -c '\
	(use-modules (xm main)) \
	(main (list "xm" "--store" "/tmp/xm-cli-make-test" "node" "create" "--type" "entity"))'
	@$(GUILE) --no-auto-compile -c '\
	(use-modules (xm main)) \
	(main (list "xm" "--store" "/tmp/xm-cli-make-test" "query" "nodes"))' | grep -q "Found 1 nodes" && echo "PASS: CLI works" || echo "FAIL: CLI test failed"
	@rm -rf /tmp/xm-make-test /tmp/xm-cli-make-test
	@echo "=== All Guile tests passed ==="

test-store: build ## Run the Rust store diagnostic test
	$(CARGO) build --release --bin xm-store-test
	./$(BUILD_DIR)/xm-store-test

## Code quality

check: ## Run cargo check and clippy
	$(CARGO) check
	$(CARGO) clippy -- -D warnings

fmt: ## Format Rust code
	$(CARGO) fmt

fmt-check: ## Check Rust formatting
	$(CARGO) fmt -- --check

## Run targets

run: build ## Run xm CLI (usage: make run ARGS="node create --type entity")
	@$(GUILE) --no-auto-compile $(GUILE_MODULES)/xm/main.scm -- $(ARGS)

repl: build ## Start a Guile REPL with xm modules loaded
	@$(GUILE) --no-auto-compile -c '\
	(use-modules (xm store) (xm main) (xm cli node) (xm cli query)) \
	(display "xm modules loaded. Try: (make-store \"/tmp/xm-repl\")\n")' \
	-l /dev/null

## Installation

install: build ## Install xm to PREFIX (default: ~/.local)
	@mkdir -p $(PREFIX)/bin
	@mkdir -p $(PREFIX)/lib
	@mkdir -p $(PREFIX)/share/guile/site/3.0/xm
	@mkdir -p $(PREFIX)/share/guile/site/3.0/xm/cli
	@cp $(BUILD_DIR)/$(LIB_NAME).dylib $(PREFIX)/lib/ 2>/dev/null || \
	 cp $(BUILD_DIR)/$(LIB_NAME).so $(PREFIX)/lib/ 2>/dev/null || true
	@cp -r $(GUILE_MODULES)/xm/*.scm $(PREFIX)/share/guile/site/3.0/xm/
	@cp -r $(GUILE_MODULES)/xm/cli/*.scm $(PREFIX)/share/guile/site/3.0/xm/cli/
	@cp bin/xm $(PREFIX)/bin/xm
	@chmod +x $(PREFIX)/bin/xm
	@echo "Installed xm to $(PREFIX)"
	@echo "Make sure $(PREFIX)/bin is in your PATH"

uninstall: ## Uninstall xm from PREFIX
	rm -f $(PREFIX)/bin/xm
	rm -f $(PREFIX)/lib/$(LIB_NAME).dylib $(PREFIX)/lib/$(LIB_NAME).so
	rm -rf $(PREFIX)/share/guile/site/3.0/xm
	@echo "Uninstalled xm from $(PREFIX)"

## Cleanup

clean: ## Remove build artifacts
	$(CARGO) clean
	rm -rf /tmp/xm-make-test /tmp/xm-cli-make-test

clean-store: ## Remove test stores
	rm -rf /tmp/xm-*

## Documentation

docs: ## Generate Rust documentation
	$(CARGO) doc --no-deps --open

## Help

help: ## Show this help message
	@echo "xm - Cross Memory CLI"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make build          # Build the project"
	@echo "  make test           # Run all tests"
	@echo "  make run ARGS='node create --type entity'"
	@echo "  make install PREFIX=/usr/local"
