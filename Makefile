.PHONY: sync lint test app-test gitops-lint helm-lint validate render render-tenants drift-check schema-check check kind-up kind-up-argocd kind-down

CLI_DIR := platform/cli
APP_DIR := apps/payments-api
CHART_DIR := platform/charts/web-service
SERVICE_SPECS := $(sort $(wildcard services/*/service.yaml))
KUBECONFORM ?= kubeconform
K8S_VERSION := 1.35.0

sync:
	uv sync --locked --directory $(CLI_DIR) --extra dev

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
	@for spec in $(SERVICE_SPECS); do \
		uv run --project $(CLI_DIR) idp validate $$spec --env all || exit 1; \
	done

render-tenants:
	uv run --project $(CLI_DIR) idp render-tenants --teams-dir teams --out-dir rendered-tenants

render: render-tenants
	@for spec in $(SERVICE_SPECS); do \
		uv run --project $(CLI_DIR) idp render $$spec --env all --out-dir rendered || exit 1; \
	done

# Untracked output counts as drift too: a new service or team must be committed rendered.
drift-check: render
	git diff --exit-code rendered/ rendered-tenants/
	@untracked="$$(git ls-files --others --exclude-standard rendered/ rendered-tenants/)"; \
		test -z "$$untracked" || { echo "Untracked rendered output:"; echo "$$untracked"; exit 1; }

schema-check:
	$(KUBECONFORM) -strict -summary -kubernetes-version $(K8S_VERSION) \
		rendered/*/*/manifests.yaml rendered-tenants/*/*/tenant.yaml

check: lint test app-test gitops-lint helm-lint validate drift-check schema-check

kind-up:
	./platform/kind/bootstrap.sh

kind-up-argocd:
	./platform/kind/bootstrap.sh --with-argocd

kind-down:
	./platform/kind/teardown.sh
