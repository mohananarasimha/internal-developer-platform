# GitOps & Argo CD Configuration

This directory defines the Argo CD Applications that reconcile platform-owned tenant namespaces and rendered service manifests from Git onto the target cluster.

## Files

- `tenants-application.yaml`: Application `idp-tenants` syncing `rendered-tenants/` (rendered by `idp render-tenants` from `teams/*.yaml`). Each team gets one namespace per environment, `<team>-<env>`, with:
  - Pod Security Admission `restricted`. The `web-service` chart renders workloads that pass it without exemptions.
  - A RoleBinding of the `edit` ClusterRole to the team's group.
  - A ResourceQuota, which also forbids LoadBalancer and NodePort Services.
  - A LimitRange with default container requests and limits.
  - NetworkPolicies that deny ingress from other namespaces except teams listed in `allowIngressFrom`, in the same environment.

  `prune: false`: removing a team from Git never deletes a namespace automatically.
- `argocd-cm.yaml`: Sets `application.resourceTrackingMethod: annotation` in `argocd/argocd-cm`. Applied by `platform/kind/bootstrap.sh --with-argocd` right after installing Argo CD `v2.14.2`.
- `applicationset.yaml`: Uses Argo CD's Git files generator over `rendered/*/*/values.yaml` (`rendered/<env>/<service>`). It reconciles `manifests.yaml` into the `namespace` recorded in that values file, which is the owning team's tenant namespace, with `prune: true`, `selfHeal: true`, and `CreateNamespace=false`.

## Key Design Decisions

### Annotation-Based Resource Tracking (`argocd-cm.yaml`)
Argo CD 2.x defaults to `label` tracking, which writes the Argo CD Application name (for example `prod-payments-api`) into `metadata.labels["app.kubernetes.io/instance"]` on every managed resource. Because `platform/charts/web-service` already sets `app.kubernetes.io/instance: payments-api` on Deployments, Services, PDBs, and HPAs, default label tracking mutates that label and causes ownership/diff conflicts. Switching `application.resourceTrackingMethod` to `annotation` stores tracking metadata in `argocd.argoproj.io/tracking-id` instead and leaves chart labels untouched. Verified live on `kind` with Argo CD `v2.14.2` (`prod-payments-api` and `staging-payments-api` both `Synced / Healthy`).

### Explicit Namespace Management (`CreateNamespace=false`)
Namespaces are owned by the platform (`idp-tenants`), never auto-created by application syncs. This ensures Pod Security Admission labels (`restricted`), resource quotas, and network policies exist before any workload can schedule. `bootstrap.sh` applies `rendered-tenants/` before the ApplicationSet for the same reason.

### HPA + `selfHeal` Reconciliation (`ignoreDifferences` + `RespectIgnoreDifferences=true`)
Because `Deployment.spec.replicas` is managed dynamically by `HorizontalPodAutoscaler` when `maxReplicas > minReplicas`, `applicationset.yaml` pairs `ignoreDifferences` on `/spec/replicas` with `RespectIgnoreDifferences=true` in `syncPolicy.syncOptions`. `ignoreDifferences` alone only suppresses `OutOfSync` diff reporting—during an actual sync (for example on an image tag update), Argo CD still applies the `spec.replicas` value from Git and resets HPA-scaled workloads back to `minReplicas`. Setting `RespectIgnoreDifferences=true` tells Argo CD to also exclude those ignored paths during sync apply so HPA owns replica scaling end-to-end. Verified live on `kind`: scaling `payments-api` to 3 replicas and triggering `argocd.argoproj.io/refresh=hard` left Argo CD `Synced` with no sync operation while the HPA scaled the Deployment back to 2.

### Multi-Team Production Sync Strategy: Staging Auto-Sync vs. Prod Sync Gates
In this single-repo local setup, `applicationset.yaml` uses automated sync across `rendered/*/*` to make local GitOps demos and rollback experiments deterministic. In a multi-team production environment, platform teams split this into two distinct `ApplicationSet` policies:

1. **Staging (`rendered/staging/*`)**: Automated sync (`prune: true`, `selfHeal: true`) on merge to `main` for fast developer feedback and continuous integration verification.
2. **Production (`rendered/prod/*`)**:
   - **Gated promotion**: Either remove `syncPolicy.automated` (requiring explicit operator/pipeline `argocd app sync` after staging soak checks), or enforce CODEOWNERS + CI soak-test checks on PRs modifying `rendered/prod/**`.
   - **Sync windows**: Restrict automated prod syncs to approved change windows via Argo CD `AppProject.spec.syncWindows`, allowing manual emergency rollbacks at any time.
   - **Scoped `AppProject` RBAC**: Bind each team's `AppProject` to its dedicated namespaces and allowed resource kinds so a single service repo cannot mutate cluster-scoped objects.
