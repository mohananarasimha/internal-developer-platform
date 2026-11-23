.PHONY: sync lint test helm-lint validate render drift-check check

CLI_DIR := platform/cli
CHART_DIR := platform/charts/web-service
SAMPLE_SPEC := services/payments-api/service.yaml

sync:
	uv sync --directory $(CLI_DIR) --extra dev

lint:
	uv run --directory $(CLI_DIR) ruff check .

test:
	uv run --directory $(CLI_DIR) pytest -v

helm-lint:
	helm lint $(CHART_DIR)

validate:
	uv run --project $(CLI_DIR) idp validate $(SAMPLE_SPEC) --env all

render:
	uv run --project $(CLI_DIR) idp render $(SAMPLE_SPEC) --env all --out-dir rendered

drift-check: render
	git diff --exit-code rendered/

check: lint test helm-lint validate drift-check
