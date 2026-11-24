# GitOps & Argo CD Configuration

This directory defines cluster-level namespace policies and the Argo CD `ApplicationSet` that reconciles rendered service manifests from Git onto the target cluster.

## Files

- `namespaces.yaml`: Declares `staging` and `prod` namespaces with Kubernetes Pod Security Admission set to `restricted` (`enforce`, `warn`, and `audit`). Because `platform/charts/web-service` renders non-root, read-only-root-filesystem, `drop: ["ALL"]`, `RuntimeDefault` seccomp workloads by default, every platform service passes `restricted` admission without exemptions.
- `applicationset.yaml`: Uses Argo CD's Git directory generator over `rendered/*/*` (`rendered/<env>/<service>`), reconciling `manifests.yaml` into namespace `{{path[1]}}` with `prune: true`, `selfHeal: true`, and `CreateNamespace=false`.

## Key Design Decisions

### Explicit Namespace Management (`CreateNamespace=false`)
Namespaces are owned by the platform (`namespaces.yaml`), never auto-created by application syncs. This ensures Pod Security Admission labels (`restricted`), resource quotas, and network policies exist before any workload can schedule.

### HPA + `selfHeal` Reconciliation (`ignoreDifferences`)
Because `Deployment.spec.replicas` is managed dynamically by `HorizontalPodAutoscaler` when `maxReplicas > minReplicas`, `applicationset.yaml` ignores `/spec/replicas` diffs on `apps/v1` `Deployment`. Without this, Argo CD `selfHeal: true` would continuously revert scaled-out replica counts back to `minReplicas`.

### Multi-Team Production Sync Strategy: Staging Auto-Sync vs. Prod Sync Gates
In this single-repo local setup, `applicationset.yaml` uses automated sync across `rendered/*/*` to make local GitOps demos and rollback experiments deterministic. In a multi-team production environment, platform teams split this into two distinct `ApplicationSet` policies:

1. **Staging (`rendered/staging/*`)**: Automated sync (`prune: true`, `selfHeal: true`) on merge to `main` for fast developer feedback and continuous integration verification.
2. **Production (`rendered/prod/*`)**:
   - **Gated promotion**: Either remove `syncPolicy.automated` (requiring explicit operator/pipeline `argocd app sync` after staging soak checks), or enforce CODEOWNERS + CI soak-test checks on PRs modifying `rendered/prod/**`.
   - **Sync windows**: Restrict automated prod syncs to approved change windows via Argo CD `AppProject.spec.syncWindows`, allowing manual emergency rollbacks at any time.
   - **Scoped `AppProject` RBAC**: Bind each team's `AppProject` to its dedicated namespaces and allowed resource kinds so a single service repo cannot mutate cluster-scoped objects.
