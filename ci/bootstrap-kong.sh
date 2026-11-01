#!/usr/bin/env bash
# Reconciles the versioned gateway configuration even on an existing cluster.
# A completed Kubernetes Job does not rerun when its Secret changes.
# Usage: KUBE_CONTEXT=aws-fiapgames ci/bootstrap-kong.sh [manifests-dir] [config-file]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-fiapgames}"
MANIFESTS="${1:-$ROOT/k8s/kong}"
CONFIG="${2:-$ROOT/kong/kong.k8s.yml}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

kctl create secret generic kong-declarative-config -n "$NAMESPACE" \
  --from-file="kong.yml.template=$CONFIG" --dry-run=client -o yaml | kctl apply -f -

# Recreate only the import Job. Keep Postgres, the Kong Deployment and all
# application data in place. Both migration bootstrap and db_import are idempotent.
kctl delete job kong-bootstrap -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=120s
kctl apply -n "$NAMESPACE" -f "$MANIFESTS"
kctl wait --for=condition=complete job/kong-bootstrap -n "$NAMESPACE" --timeout=600s

# db_import updates the database without invalidating the workers' router cache.
kctl rollout restart deployment/kong -n "$NAMESPACE"
kctl rollout status deployment/kong -n "$NAMESPACE" --timeout=300s
