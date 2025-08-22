# go-utility-scripts Makefile

SHELL := /bin/bash

# Default target
.DEFAULT_GOAL := usage

# Paths
ROOT_DIR      := $(CURDIR)
SCRIPTS_DIR   := $(ROOT_DIR)/scripts
CHECK_SCRIPT  := $(SCRIPTS_DIR)/check_go_version.bash
ENSURE_SCRIPT := $(SCRIPTS_DIR)/ensure_latest_go.bash

# Options propagated to scripts (can be overridden: make ensure-go QUIET=1)
QUIET ?=
FORCE_DIRECT_INSTALL ?=
DRY_RUN ?=

.PHONY: usage check-go ensure-go install-shell-hook uninstall-shell-hook print-shell-hook \
        _install_shell_hook _remove_shell_hook

usage:
	@echo "go-utility-scripts - Go toolchain management utilities"
	@echo ""
	@echo "USAGE:"
	@echo "  make <target> [OPTIONS]"
	@echo ""
	@echo "TARGETS:"
	@echo "  usage                   Show this help message (default target)"
	@echo "  check-go                Check if local Go version matches latest stable"
	@echo "  ensure-go               Install/update to latest stable Go version"
	@echo "  install-shell-hook      Install auto-update hook into ~/.bashrc and ~/.zshrc"
	@echo "  uninstall-shell-hook    Remove auto-update hook from shell rc files"
	@echo "  print-shell-hook        Print the exact hook block that will be installed"
	@echo ""
	@echo "OPTIONS (for ensure-go target):"
	@echo "  QUIET=1                 Suppress non-error output"
	@echo "  FORCE_DIRECT_INSTALL=1  Force direct install (bypass package managers)"
	@echo "  DRY_RUN=1               Show what would be done without executing"
	@echo ""
	@echo "EXAMPLES:"
	@echo "  make check-go                    # Check current Go version"
	@echo "  make ensure-go                   # Update to latest Go"
	@echo "  make ensure-go QUIET=1          # Update quietly"
	@echo "  make ensure-go DRY_RUN=1        # Preview update actions"
	@echo "  make install-shell-hook         # Auto-update on shell startup"
	@echo ""

check-go:
	@echo "[check-go] $(CHECK_SCRIPT)"
	@bash "$(CHECK_SCRIPT)"

ensure-go:
	@echo "[ensure-go] $(ENSURE_SCRIPT)"
	@CHECK_SCRIPT="$(CHECK_SCRIPT)" QUIET="$(QUIET)" FORCE_DIRECT_INSTALL="$(FORCE_DIRECT_INSTALL)" DRY_RUN="$(DRY_RUN)" \
	  bash "$(ENSURE_SCRIPT)"

# ---------------- Shell Hook Installation ----------------
# We install a guarded block into the user's shell rc files so that, on shell startup,
# ensure_latest_go.bash runs (quietly by default) to keep Go up to date.

# Marker strings used to add/remove the block safely
HOOK_BEGIN := >>> go-utility-scripts ensure_latest_go.bash (make install-shell-hook) >>>
HOOK_END   := <<< go-utility-scripts ensure_latest_go.bash <<<

# Multiline hook block to append into rc files
# NOTE: Uses double-quoted expansion in the shell so $(...) are not resolved by make.
define HOOK_BLOCK
# $$(HOOK_BEGIN)
# Runs once per login shell to ensure latest stable Go toolchain is installed.
if [ -f "$(ENSURE_SCRIPT)" ]; then
  CHECK_SCRIPT="$(CHECK_SCRIPT)" QUIET=1 bash "$(ENSURE_SCRIPT)"
fi
# $$(HOOK_END)
endef
export HOOK_BLOCK

print-shell-hook:
	@printf '%s\n' "$(HOOK_BLOCK)"

install-shell-hook: _install_shell_hook_bash _install_shell_hook_zsh
	@echo "Installed shell hook into any present rc files."

uninstall-shell-hook: _remove_shell_hook_bash _remove_shell_hook_zsh
	@echo "Removed shell hook from any present rc files."

_install_shell_hook_bash:
	@$(MAKE) _install_shell_hook RC_FILE="$$HOME/.bashrc"

_install_shell_hook_zsh:
	@$(MAKE) _install_shell_hook RC_FILE="$$HOME/.zshrc"

_remove_shell_hook_bash:
	@$(MAKE) _remove_shell_hook RC_FILE="$$HOME/.bashrc"

_remove_shell_hook_zsh:
	@$(MAKE) _remove_shell_hook RC_FILE="$$HOME/.zshrc"

_install_shell_hook:
	@rc="$(RC_FILE)"; \
	if [ ! -e "$$rc" ]; then touch "$$rc"; fi; \
	if grep -Fq "$(HOOK_BEGIN)" "$$rc"; then \
	  printf 'Hook already present in %s\n' "$$rc"; \
	else \
	  printf 'Installing hook into %s\n' "$$rc"; \
	  printf '%s\n' "$$HOOK_BLOCK" >> "$$rc"; \
	fi

_remove_shell_hook:
	@rc="$(RC_FILE)"; \
	if [ ! -e "$$rc" ]; then printf 'No rc file at %s\n' "$$rc"; exit 0; fi; \
	if ! grep -Fq "$(HOOK_BEGIN)" "$$rc"; then \
	  printf 'Hook not found in %s\n' "$$rc"; \
	else \
	  printf 'Removing hook from %s\n' "$$rc"; \
	  cp "$$rc" "$$rc.bak"; \
	  awk 'BEGIN{skip=0} index($$0,"$(HOOK_BEGIN)"){skip=1;next} index($$0,"$(HOOK_END)"){skip=0;next} !skip{print}' "$$rc" > "$$rc.tmp" && mv "$$rc.tmp" "$$rc"; \
	fi
