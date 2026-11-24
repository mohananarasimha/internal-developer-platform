.PHONY: sync lint test app-test gitops-lint helm-lint validate render drift-check check kind-up kind-up-argocd kind-down

CLI_DIR := platform/cli
APP_DIR := apps/payments-api
CHART_DIR := platform/charts/web-service
SAMPLE_SPEC := services/payments-api/service.yaml

sync:
	uv sync --directory $(CLI_DIR) --extra dev

lint:
	uv run --directory $(CLI_DIR) ruff check .
	uv run --project $(CLI_DIR) ruff check --config $(CLI_DIR)/pyproject.toml $(APP_DIR)

test:
	uv run --directory $(CLI_DIR) pytest -v

app-test:
	uv run --project $(CLI_DIR) pytest -v $(APP_DIR)/tests/test_app.py

gitops-lint:
	uv run --project $(CLI_DIR) python -c 'from pathlib import Path; import yaml; [print("OK", p, len([d for d in yaml.safe_load_all(p.read_text(encoding="utf-8")) if d is not None]), "doc(s)") for p in sorted(Path("gitops/argocd").glob("*.yaml"))]'

helm-lint:
	helm lint $(CHART_DIR)

validate:
	uv run --project $(CLI_DIR) idp validate $(SAMPLE_SPEC) --env all

render:
	uv run --project $(CLI_DIR) idp render $(SAMPLE_SPEC) --env all --out-dir rendered

drift-check: render
	git diff --exit-code rendered/

check: lint test app-test gitops-lint helm-lint validate drift-check

kind-up:
	./platform/kind/bootstrap.sh

kind-up-argocd:
	./platform/kind/bootstrap.sh --with-argocd

kind-down:
	./platform/kind/teardown.sh
