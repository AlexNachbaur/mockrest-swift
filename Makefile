# One entry point for the checks every change must pass. `make check` is what AGENTS.md,
# CONTRIBUTING.md, and the PR template mean by "the checks"; CI runs the same commands except
# `docs`, which is deliberately local-only.

SOURCES := Sources Tests Package.swift
DOC_TARGETS := MockRESTCore MockREST

.PHONY: check build test lint format docs

check: lint build test docs

build:
	swift build

test:
	swift test

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format --in-place --recursive $(SOURCES)

# DocC must build with zero warnings. CI does not run this, so a documentation regression is
# only ever caught here.
docs:
	swift package generate-documentation $(foreach target,$(DOC_TARGETS),--target $(target)) --warnings-as-errors
