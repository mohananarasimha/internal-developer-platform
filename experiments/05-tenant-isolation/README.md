# Experiment 05: Shared Environment Namespace vs. Tenant Namespaces

## QUESTION

Two teams deploy to the same cluster. If both teams' services share one environment namespace, what can one team's developer and one team's pods do to the other team? And does the platform's tenant bundle (`teams/<team>.yaml` rendered to `<team>-<env>` namespaces) actually stop it on a live cluster?

## HYPOTHESIS

- **shared:** in one namespace, the only namespace-scoped way to let both teams deploy is to bind both groups to `edit` in that namespace. Each team can then read the other's Secrets, scale or delete its Deployments, and exec into its pods. Pods reach each other freely, and one team can create as many pods as the cluster will schedule.
- **tenant:** with `edit` bound per team namespace, a default-deny ingress policy and a quota, every cross-team API call is Forbidden. Cross-team traffic is blocked unless the receiving team lists the caller in `allowIngressFrom`, and a runaway deployment stops at the team's quota.

## SETUP

- **Cluster:** `kind` `idp-local` (Kubernetes v1.35.0, 1 control-plane + 1 worker). kindnet image `kindnetd:v20251212-v0.29.0-alpha-105-g20ccfc88`. Before the runs, I checked that it enforces NetworkPolicy: a probe pod reached a server pod, then got `URLError` after a deny-all ingress policy was applied.
- **Services:** `payments-api` (owner `payments-team`) and `ledger-api` (owner `ledger-team`), both rendered for staging from the same chart and image.
- **Teams:** [`teams/payments-team.yaml`](../../teams/payments-team.yaml) allows ingress from `ledger-team`. [`teams/ledger-team.yaml`](../../teams/ledger-team.yaml) allows nobody. Staging quota for both teams: `pods: 6`, `requests.cpu: 1`, `limits.cpu: 2`.
- **Actor:** every API check runs as `dev@payments.example` in group `team:payments-team`, via `kubectl --as/--as-group` impersonation from the cluster admin. Mutating calls use `--dry-run=server`, so they pass through authorization and admission without changing anything. The exec check uses `kubectl auth can-i` (a SubjectAccessReview).
- **Network probes:** pods running the same image in the source namespace, under restricted Pod Security. Each does an HTTP GET of the target Service's `/healthz` with a 3 s timeout.
- **Quota probe:** the payments developer applies a 10-replica Deployment (100m/128Mi requests, 250m/256Mi limits). Pods are counted 20 s later and the ReplicaSet `FailedCreate` message is recorded.

[`run-experiment.sh`](run-experiment.sh):
- `shared` creates `exp05-shared` (restricted PSA, both RoleBindings, synthetic Secrets) and deploys both rendered staging services into it, with only the namespace rewritten. It deletes the namespace afterwards.
- `tenant` runs the same checks against the live, Argo CD-managed `payments-team-staging` and `ledger-team-staging`.

```bash
./experiments/05-tenant-isolation/run-experiment.sh shared 1
./experiments/05-tenant-isolation/run-experiment.sh tenant 1
./experiments/05-tenant-isolation/netpol-selfheal.sh 1   # follow-up, see below
```

## VARIABLE

Tenancy model: one shared namespace with both teams bound to `edit` (`shared`), vs. the platform-rendered per-team namespaces (`tenant`). Images, manifests (apart from the namespace) and the actor are identical.

## METRIC

The outcome of each check: `ALLOWED` / `DENIED` for API calls, `REACHABLE` / `BLOCKED` for traffic, and pods created out of 10 for the runaway Deployment.

## RESULT

Shared: 3 trials. Tenant: 2 trials. Raw rows are in [`results/`](results/).

| Check (as payments-team) | shared | tenant |
|---|---|---|
| Read own Secret `payments-db-credentials` (control) | ALLOWED ×3 | ALLOWED ×2 |
| Read `ledger-db-credentials` | ALLOWED ×3 | DENIED ×2 (`cannot get resource "secrets" ... in the namespace "ledger-team-staging"`) |
| Scale `ledger-api` to 0 | ALLOWED ×3 | DENIED ×2 (`cannot get resource "deployments"`: `kubectl scale` reads the object first) |
| Delete `ledger-api` | ALLOWED ×3 | DENIED ×2 (`cannot delete resource "deployments"`) |
| `create pods/exec` in ledger's namespace | ALLOWED ×3 | DENIED ×2 |
| Traffic: payments pod → payments-api (control) | REACHABLE in trials 2 and 3; BLOCKED in trial 1 (see below) | REACHABLE ×2 |
| Traffic: payments pod → ledger-api | REACHABLE ×3 | BLOCKED ×2 (`URLError: timed out`) |
| Traffic: ledger pod → payments-api (allowed peer) | REACHABLE ×3 | REACHABLE ×2 |
| Traffic: ledger staging pod → payments-api in prod | n/a (single namespace) | BLOCKED ×2 (`timed out`) |
| Runaway 10-replica Deployment | 10/10 pods created ×3 | 5/10 ×2: `exceeded quota: team-quota, requested: pods=1, used: pods=6, limited: pods=6` |

In tenant mode, the existing `payments-api` pod plus 5 runaway pods reached the 6-pod limit. CPU (6 × 250m = 1.5 of 2 limit) was not the binding constraint.

**Shared trial 1, control probe:** the same-namespace probe failed with `URLError` (the reason was not captured in that version of the script). It ran a few seconds after the Services were created. The second probe in the same namespace, a few seconds later, succeeded, and so did every probe in trials 2 and 3. Since then the script logs the error reason and waits for a ready EndpointSlice before probing. I report trial 1 as a setup timing failure, not as a result about isolation.

### Follow-up: what the tenant can still change about its own isolation

The `edit` ClusterRole bound by the tenant bundle was checked with `auth can-i` as the payments developer in `payments-team-staging`:

| Action | Allowed |
|---|---|
| delete `networkpolicies` | **yes** |
| delete `resourcequotas` | no |
| delete `limitranges` | no |
| create `rolebindings` | no |

So a team can remove the deny-ingress policy on its own namespaces, which opens *its own* pods to other namespaces. It cannot reach into other teams' namespaces this way. [`netpol-selfheal.sh`](netpol-selfheal.sh) deleted `default-deny-ingress` as the payments developer and timed the Argo CD `idp-tenants` self-heal: the policy was recreated after **0.6 s, 0.7 s and 5.7 s** in three runs. Traffic during that gap was not measured.

## INTERPRETATION

- In a shared namespace, Kubernetes RBAC has no boundary to draw between the teams. Bindings are per namespace, so both teams get identical rights over everything in it, including each other's Secrets. Isolation there would depend on every team behaving well.
- Per-team namespaces turn the same `edit` role into a real boundary. Every cross-team call was refused by the API server, the deny-ingress policy blocked cross-team and cross-environment traffic, and the peer allow-list let exactly the declared direction through (ledger → payments, not payments → ledger).
- The quota turns a runaway deployment from "whatever the cluster will schedule" into "at most the team's budget". The rest of the replicas fail visibly as `FailedCreate` events in the team's own namespace.
- The tenant can weaken its own ingress isolation, because `edit` includes NetworkPolicy writes. GitOps self-heal limits the exposure to seconds, but it doesn't prevent it.

## LESSON

Namespace-per-team is what makes RBAC, NetworkPolicy and quota meaningful. Put two teams in one namespace and all three controls can only be all-or-nothing. The platform should own the guardrail objects in each tenant namespace, and should not grant teams a role that can edit them. Here, `edit` still could (NetworkPolicy), and Argo CD self-heal is a backstop for that, not a substitute.

## LIMITATIONS

- Identities are impersonated (`--as`, `--as-group`). There is no real identity provider or OIDC group mapping on kind.
- Network checks probe Service ClusterIPs on one CNI (kindnet). Egress is not restricted by the tenant bundle; it was not tested.
- Each check ran a handful of times on a deterministic setup (3 shared, 2 tenant trials). These are pass/fail facts about this configuration, not rates.
- Not covered: Argo CD `AppProject` per team. Today any `services/*/service.yaml` can name any team in `metadata.owner`, and CODEOWNERS on `services/` and `teams/` is the intended control. Also not covered: a custom team role without NetworkPolicy write, and node-level isolation (shared nodes, noisy-neighbour CPU).
