.PHONY: format lint test tests integration_test integration_tests help lint_package

.DEFAULT_GOAL := help

######################
# TESTING
######################

TEST_FILE ?= tests/unit_tests/ tests/test_import.py
PYTEST_EXTRA ?=

integration_test integration_tests: TEST_FILE=tests/integration_tests/

test: ## Run unit tests (no MXC executor needed)
test tests:
	uv run --group test pytest -vv $(PYTEST_EXTRA) --disable-socket --allow-unix-socket $(TEST_FILE)

integration_test: ## Run integration tests against the real MXC executor on this machine
integration_test integration_tests:
	uv run --group test pytest -vv --timeout 120 $(PYTEST_EXTRA) $(TEST_FILE)

######################
# LINTING AND FORMATTING
######################

PYTHON_FILES=.
lint format: PYTHON_FILES=.
lint_package: ## Lint only the package
lint_package: PYTHON_FILES=langchain_mxc

lint: ## Run linters
lint lint_package:
	[ "$(PYTHON_FILES)" = "" ] || uv run --group test ruff check $(PYTHON_FILES)
	[ "$(PYTHON_FILES)" = "" ] || uv run --group test ruff format $(PYTHON_FILES) --diff

format: ## Run code formatters
format:
	[ "$(PYTHON_FILES)" = "" ] || uv run --group test ruff format $(PYTHON_FILES)
	[ "$(PYTHON_FILES)" = "" ] || uv run --group test ruff check --fix $(PYTHON_FILES)

######################
# HELP
######################

help: ## Show this help message
	@echo "Usage: make [target] [TEST_FILE=path/to/tests/]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
