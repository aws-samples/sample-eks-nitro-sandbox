#!/usr/bin/env bash
# Set up the docker-builds sample: the namespace and ServiceAccount, the egress policy, the
# EBS layer cache claim, the build scripts, and the interactive build pod.
#
#   ./scripts/setup.sh
#
# It changes nothing cluster-wide. Network policy enforcement and the StorageClass are the
# cluster operator's; this script checks them and stops with the command when one is
# missing. It creates the namespace only when it is absent, and reuses one only when it
# carries this sample's label, so it never adopts a namespace another workload owns.
#
# Overridable (the defaults match the page):
#   NAMESPACE      the namespace to run in                 (default docker-builds-sample)
#   STORAGE_CLASS  the EBS StorageClass for the layer cache (default: the cluster default
#                  when it fits: provisioner ebs.csi.eks.amazonaws.com, gp3, encrypted)
#   KUBE_CONTEXT   the kube context to pin this run to      (default: the current context)
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SAMPLE_DIR"

NAMESPACE="${NAMESPACE:-docker-builds-sample}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
SAMPLE_LABEL="app.kubernetes.io/part-of=docker-builds"
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'
WANT_PROVISIONER="ebs.csi.eks.amazonaws.com"
STATE_FILE="$SAMPLE_DIR/.docker-builds.state"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Pin the kube context for this run, so no kubectl call lands on whatever the shared current
# context happens to be.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
ctx="$(kc config current-context 2>/dev/null || true)"
[[ -n "$ctx" ]] || die "no kube context (set KUBE_CONTEXT or a current context)"
echo "kube context: $ctx"

kc get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || die "the isolated-sandbox runtime class is not on this cluster; run the Getting started samples first"

# Network policy enforcement is a cluster-wide setting the reader turns on once, as a step on
# the page. Check it and stop; never change the ConfigMap.
np="$(kc get configmap -n kube-system amazon-vpc-cni \
  -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null || true)"
[[ "$np" == "true" ]] || die "network policy enforcement is off on this cluster (amazon-vpc-cni
enable-network-policy-controller is '${np:-unset}'). Turn it on once per cluster, as the
page's step before this script describes, then run this again:
  kubectl apply -f ../../getting-started/coding-agent/enable-network-policy.yaml"

echo "Step 1/5: choose the StorageClass for the layer cache"
# A StorageClass is cluster-wide, so this sample only ever chooses one: the class named in
# STORAGE_CLASS, or the cluster's default when it fits. It never creates, patches or deletes
# a class. A read that fails is "could not determine", which stops the run.
sc_param() {  # sc_param <class> <jsonpath> -> value on stdout, non-zero on a read failure
  kc get storageclass "$1" --ignore-not-found -o "jsonpath=$2"
}
if [[ -n "$STORAGE_CLASS" ]]; then
  prov="$(sc_param "$STORAGE_CLASS" '{.provisioner}')" \
    || die "could not read StorageClass '$STORAGE_CLASS'; re-run once the cluster reads cleanly"
  [[ -n "$prov" ]] || die "STORAGE_CLASS='$STORAGE_CLASS' does not exist on this cluster"
  [[ "$prov" == "$WANT_PROVISIONER" ]] \
    || die "STORAGE_CLASS='$STORAGE_CLASS' uses provisioner '$prov', not '$WANT_PROVISIONER'"
  CHOSEN_CLASS="$STORAGE_CLASS"
  echo "  STORAGE_CLASS names '$CHOSEN_CLASS' (provisioner '$prov'). Using it."
else
  defaults="$(kc get storageclass \
    -o 'jsonpath={range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')" \
    || die "could not list the cluster's StorageClasses; re-run once the cluster reads cleanly"
  mapfile -t default_list < <(printf '%s\n' "$defaults" | sed '/^$/d')
  [[ "${#default_list[@]}" -eq 1 ]] || die "this cluster has ${#default_list[@]} default StorageClasses, so none can be
chosen unambiguously. Name one with STORAGE_CLASS=<class> (it must use $WANT_PROVISIONER)."
  CHOSEN_CLASS="${default_list[0]}"
  prov="$(sc_param "$CHOSEN_CLASS" '{.provisioner}')" \
    || die "could not read the default StorageClass '$CHOSEN_CLASS'; re-run once the cluster reads cleanly"
  type_param="$(sc_param "$CHOSEN_CLASS" '{.parameters.type}')" \
    || die "could not read parameters.type of '$CHOSEN_CLASS'; re-run once the cluster reads cleanly"
  enc="$(sc_param "$CHOSEN_CLASS" '{.parameters.encrypted}')" \
    || die "could not read parameters.encrypted of '$CHOSEN_CLASS'; re-run once the cluster reads cleanly"
  if [[ "$prov" != "$WANT_PROVISIONER" || ( -n "$type_param" && "$type_param" != "gp3" ) || "$enc" != "true" ]]; then
    die "the cluster's default StorageClass '$CHOSEN_CLASS' does not fit this sample
(provisioner '$prov', type '${type_param:-<unset>}', encrypted '${enc:-<unset>}'; it needs
$WANT_PROVISIONER, gp3 and encrypted). This sample never creates or changes a StorageClass.
Name a class that fits with STORAGE_CLASS=<class>, or create one first: the Storage > EBS
volumes sample ships a gp3, encrypted, non-default class in deploy/storage-class.yaml."
  fi
  echo "  the cluster default StorageClass '$CHOSEN_CLASS' fits (provisioner $prov, gp3, encrypted). Using it."
fi

echo "Step 2/5: the namespace and the build ServiceAccount"
render() { sed -e "s|<NAMESPACE>|$NAMESPACE|g" "$@"; }
# Split the two documents in deploy/namespace.yaml: the namespace is CREATED only when
# absent (applying over an existing namespace would count as adopting it, and could put this
# sample's label on a namespace another demo owns), the ServiceAccount is applied either way.
ns_doc() { render deploy/namespace.yaml | awk '/^---$/{exit} {print}'; }
sa_doc() { render deploy/namespace.yaml | awk 'f{print} /^---$/{f=1}'; }
if kc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  mark="$(kc get namespace "$NAMESPACE" -o "jsonpath={.metadata.labels.$SAMPLE_LABEL_JSONPATH}")" \
    || die "could not read the labels of namespace '$NAMESPACE'; re-run once the cluster reads cleanly"
  [[ "$mark" == "docker-builds" ]] || die "namespace '$NAMESPACE' already exists and is not labelled
$SAMPLE_LABEL, so this sample did not create it. Refusing to put build pods in a namespace
another workload may own. Set NAMESPACE to a name of your own and run this again."
  echo "  reusing namespace '$NAMESPACE' (it carries $SAMPLE_LABEL)."
else
  ns_doc | kc create -f -
  echo "  created namespace '$NAMESPACE', labelled $SAMPLE_LABEL."
fi
sa_doc | kc apply -f -

echo "Step 3/5: the egress policy"
# The push rules are added only once scripts/ecr-setup.sh has created the role and the
# association, which it records in the state file. Without them the build pods have no route
# to the Pod Identity credential address or to Amazon ECR.
push_rules=""
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && . "$STATE_FILE"
if [[ "${ECR_PUSH_READY:-false}" == "true" && "${ECR_NAMESPACE:-}" != "$NAMESPACE" ]]; then
  # The recorded push belongs to another run, so its rules are not added here: this
  # namespace's pods get the policy without a credential path.
  echo "  the recorded Amazon ECR push belongs to namespace '${ECR_NAMESPACE:-unknown}', not '$NAMESPACE'; applying the policy without the push rules."
elif [[ "${ECR_PUSH_READY:-false}" == "true" ]]; then
  push_rules="$(sed -e "s|<AWS_REGION>|${ECR_AWS_REGION}|g" -e "s|<ACCOUNT_ID>|${ECR_ACCOUNT_ID}|g" \
    "$SAMPLE_DIR/deploy/egress-push-rules.yaml")"
  echo "  including the optional push rules (the state file records an ECR push set up in ${ECR_AWS_REGION})."
fi
render deploy/egress-policy.yaml \
  | awk -v rules="$push_rules" '{ if ($0 == "<ECR_PUSH_RULES>") { if (rules != "") print rules } else print }' \
  | kc apply -f -
echo "  waiting for the egress PolicyEndpoint..."
for _ in $(seq 1 60); do
  kc -n "$NAMESPACE" get policyendpoints -o name 2>/dev/null | grep -q 'docker-builds-egress' && break
  sleep 2
done
kc -n "$NAMESPACE" get policyendpoints -o name | grep -q 'docker-builds-egress' \
  || die "the PolicyEndpoint for docker-builds-egress did not appear; the policy is not on the nodes yet"
kc -n "$NAMESPACE" get applicationnetworkpolicies

echo "Step 4/5: the EBS layer cache claim and the build scripts"
# A claim's spec is immutable and keeping it across runs is what makes the second build warm,
# so it is created only when absent.
if kc -n "$NAMESPACE" get pvc docker-build-cache >/dev/null 2>&1; then
  echo "  reusing the existing docker-build-cache claim: this is what makes a re-run warm."
else
  render deploy/cache-pvc.yaml \
    | sed -e "s|<CACHE_CLAIM>|docker-build-cache|g" -e "s|<STORAGE_CLASS>|$CHOSEN_CLASS|g" \
    | kc create -f -
fi
render deploy/build-configmap.yaml | kc apply -f -
render deploy/buildkit-configmap.yaml | kc apply -f -

echo "Step 5/5: the interactive build pod"
render deploy/hello-docker.yaml | kc apply -f -
kc -n "$NAMESPACE" wait --for=condition=Ready pod/hello-docker --timeout=10m \
  || die "pod/hello-docker never became Ready. Check:
  kubectl describe pod hello-docker -n $NAMESPACE
  kubectl logs hello-docker -n $NAMESPACE"

echo
echo "hello-docker is Ready: a privileged Docker daemon is running in its own sandbox."
kc -n "$NAMESPACE" get pod hello-docker -o wide
echo
echo "Build by hand:    kubectl exec -it hello-docker -n $NAMESPACE -- sh"
echo "Run the CI build: NAMESPACE=$NAMESPACE ./scripts/run-build-job.sh"
echo "Tear down:        NAMESPACE=$NAMESPACE ./scripts/clean.sh"
