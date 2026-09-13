# Copy into your plugin repository; run make there (or make -C /path/to/repo).
.DEFAULT_GOAL := help
PREFIX ?= $(HOME)/bin
PLUGIN_NAME ?= paw-backend-acme
PLUGIN_SOURCE ?= scripts/$(PLUGIN_NAME)
# Export values so shell quotes protect spaces without make word-splitting.
export PREFIX PLUGIN_NAME PLUGIN_SOURCE

.PHONY: help install uninstall
help:
	@printf '%s\n' 'install: symlink PLUGIN_SOURCE into PREFIX/PLUGIN_NAME (default HOME/bin)' \
	  'uninstall: remove only this source-owned link; inspect conflicts manually' \
	  'Override PREFIX, PLUGIN_NAME, and PLUGIN_SOURCE on the make command line.'

install uninstall:
	@set -eu; \
	case "$$PLUGIN_NAME" in ''|.|..|*/*) echo 'error: PLUGIN_NAME must be one executable filename' >&2; exit 1;; esac; \
	case "$$PLUGIN_SOURCE" in /*) source_path="$$PLUGIN_SOURCE";; *) source_path="$$(pwd -P)/$$PLUGIN_SOURCE";; esac; \
	destination="$$PREFIX/$$PLUGIN_NAME"; \
	refuse() { printf 'error: %s: %s; inspect the destination and remove it manually if appropriate, then reinstall\n' "$$destination" "$$1" >&2; exit 1; }; \
	[ -n "$$PREFIX" ] || refuse 'PREFIX must be an executable directory'; \
	if [ '$@' = install ]; then \
	  [ -f "$$source_path" ] && [ -x "$$source_path" ] || refuse "source '$$source_path' is missing or not executable"; \
	fi; \
	if [ -L "$$destination" ] && [ "$$(readlink "$$destination")" = "$$source_path" ]; then \
	  [ ! -d "$$destination" ] || refuse 'destination points to a directory'; \
	  if [ '$@' = uninstall ]; then rm -- "$$destination"; fi; \
	elif [ -e "$$destination" ] || [ -L "$$destination" ]; then \
	  refuse 'destination is not the link owned by this source'; \
	elif [ '$@' = install ]; then \
	  mkdir -p -- "$$PREFIX"; \
	  ln -s -- "$$source_path" "$$destination"; \
	fi
