.DEFAULT_GOAL := help

PREFIX     ?= $(HOME)/bin
REPO_ROOT  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: help install uninstall test lint shellcheck check list ci-deps

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  help       — show this help' \
	  '  install    — symlink scripts/paw into PREFIX/bin (default: ~/bin)' \
	  '  uninstall  — remove the symlink from PREFIX/bin' \
	  '  test       — run the full bats test suite' \
	  '  lint       — lint all .agent/ task packages in this repo' \
	  '  shellcheck — run shellcheck over all shell scripts' \
	  '  check      — test + lint + shellcheck (canonical local validation)' \
	  '  list       — list .agent/ task packages' \
	  '  ci-deps    — install CI dependencies (bats, jq, shellcheck)'

install:
	mkdir -p "$(PREFIX)"
	ln -sf "$(REPO_ROOT)scripts/paw" "$(PREFIX)/paw"

uninstall:
	rm -f "$(PREFIX)/paw"

test:
	bats tests/

lint:
	scripts/lint-task.sh --repo .

shellcheck:
	shellcheck scripts/paw scripts/*.sh scripts/lib/*.sh scripts/lib/backends/*.sh

check: test lint shellcheck

list:
	scripts/list-tasks.sh

ci-deps:
	sudo apt-get update && sudo apt-get install -y bats jq shellcheck
