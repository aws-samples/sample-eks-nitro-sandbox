#!/usr/bin/env bash
# setup.sh -- the cluster side of this sample: the namespace, and the self-hosted GitLab.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./scripts/setup.sh
#
# What it does, in order:
#   1. checks the tools, the kube context and the isolated-sandbox RuntimeClass;
#   2. creates the namespace, if absent, and labels it as this sample's;
#   3. picks a StorageClass for GitLab's volume and checks it is an EBS CSI one. A class is
#      chosen here and never changed: the cluster's default class belongs to every other
#      workload on the cluster too;
#   4. generates GitLab's initial root password into a Secret, if that Secret is absent, so
#      the password is never an argument to any command and is not printed;
#   5. applies the GitLab Deployment, its ClusterIP Service and its volume, and waits for
#      GitLab to answer its own readiness endpoint.
#
# It creates nothing cluster-wide and no AWS resource. The only thing that reaches the
# account is the EBS volume the CSI driver provisions for GitLab's claim, which belongs to
# the claim and goes when the claim goes.
set -euo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
say "1/5 tools, context and RuntimeClass"
# ---------------------------------------------------------------------------
need_tools kubectl openssl
check_cluster
echo "  context '$KUBE_CONTEXT', isolated-sandbox present."

# ---------------------------------------------------------------------------
say "2/5 the namespace"
# ---------------------------------------------------------------------------
ns_present="$("${KCTL[@]}" get namespace "$NAMESPACE" -o name --ignore-not-found 2>/dev/null)" \
  || die "could not read namespace '$NAMESPACE'. That is a failed read, not a report that it is absent."
if [[ -n "$ns_present" ]]; then
  # Applying a manifest over a namespace that is already there counts as reusing it, so the
  # label is checked before anything else is written: on a shared cluster another demo may
  # well own a namespace of this name.
  require_namespace
  echo "  namespace '$NAMESPACE' is already this sample's; reusing it."
else
  "${KCTL[@]}" create namespace "$NAMESPACE"
  "${KCTL[@]}" label namespace "$NAMESPACE" "$LABEL_KEY=$LABEL_VALUE"
  echo "  created namespace '$NAMESPACE' and labelled it $LABEL_KEY=$LABEL_VALUE."
fi

# ---------------------------------------------------------------------------
say "3/5 the StorageClass for GitLab's volume"
# ---------------------------------------------------------------------------
# GitLab keeps its repositories, its database and its CI state on one ReadWriteOnce volume.
# The class is only ever chosen here: this script never creates one and never applies over
# one, because a StorageClass is cluster-scoped and applying over the default class can take
# its default annotation away, which changes how every other claim on the cluster is
# provisioned.
if [[ -n "${STORAGE_CLASS:-}" ]]; then
  sc="$STORAGE_CLASS"
  echo "  using STORAGE_CLASS=$sc from .env."
else
  sc="$("${KCTL[@]}" get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | head -n 1)" \
    || die "could not list StorageClasses. That is a failed read, not a report that there is no default class."
  [[ -n "$sc" ]] \
    || die "this cluster has no default StorageClass, so GitLab's volume has nothing to be provisioned by. Set STORAGE_CLASS in .env to an EBS CSI class ('kubectl get storageclass')."
  echo "  the cluster's default class is '$sc'."
fi

prov="$("${KCTL[@]}" get storageclass "$sc" -o jsonpath='{.provisioner}' 2>/dev/null)" \
  || die "could not read StorageClass '$sc'. Check the name against 'kubectl get storageclass'."
[[ -n "$prov" ]] \
  || die "StorageClass '$sc' reports no provisioner. That is a failed read, not a usable class."
# The sample needs a volume that one pod mounts read-write and that survives a restart, which
# is what the EKS Auto Mode EBS CSI driver provisions. Another provisioner may well work, but
# this sample has not been run on one, so it says so rather than assuming.
[[ "$prov" == "ebs.csi.eks.amazonaws.com" ]] \
  || die "StorageClass '$sc' uses provisioner '$prov', and this sample was proved with the EKS Auto Mode EBS CSI driver, 'ebs.csi.eks.amazonaws.com'. Set STORAGE_CLASS in .env to an EBS CSI class, or run the sample on a cluster that has one."
echo "  provisioner $prov: GitLab's volume will be an EBS volume, and goes when its claim goes."

# ---------------------------------------------------------------------------
say "4/5 GitLab's initial root password"
# ---------------------------------------------------------------------------
# GitLab reads this once, on its first boot, and from then on the password is in its
# database. So the Secret is created only when it is absent: regenerating it would leave the
# Secret holding a password GitLab no longer accepts.
#
# A read that fails is kept apart from an absent Secret, as everywhere else here.
root_present="$("${KCTL[@]}" get secret "$ROOT_SECRET" -n "$NAMESPACE" -o name --ignore-not-found 2>/dev/null)" \
  || die "could not read Secret '$ROOT_SECRET' in '$NAMESPACE'. That is a failed read, not a report that it is absent."
if [[ -n "$root_present" ]]; then
  echo "  Secret '$ROOT_SECRET' is already there; keeping it, because GitLab only reads this password on its first boot."
else
  # The password goes into the Secret from a file, never as an argument: a command line is
  # visible to other processes and lands in shell history. The file is in a private temp
  # directory and is removed on every exit path, including an interrupt.
  pw_dir="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-ci-root.XXXXXX")"
  trap 'rm -rf "$pw_dir"' EXIT INT TERM
  ( umask 077; openssl rand -base64 24 | tr -d '\n' > "$pw_dir/password" )
  [[ -s "$pw_dir/password" ]] || die "could not generate GitLab's root password."
  # `create`, not `apply`: a client-side apply copies the whole object, password included,
  # into a kubectl.kubernetes.io/last-applied-configuration annotation, and
  # `kubectl describe secret` prints annotations even though it hides data.
  "${KCTL[@]}" create secret generic "$ROOT_SECRET" -n "$NAMESPACE" \
    --from-file=password="$pw_dir/password" >/dev/null \
    || die "could not create Secret '$ROOT_SECRET'."
  "${KCTL[@]}" label secret "$ROOT_SECRET" -n "$NAMESPACE" "$LABEL_KEY=$LABEL_VALUE" >/dev/null
  rm -rf "$pw_dir"
  trap - EXIT INT TERM
  echo "  generated a root password into Secret '$ROOT_SECRET'. It is not printed here."
fi

# ---------------------------------------------------------------------------
say "5/5 GitLab"
# ---------------------------------------------------------------------------
sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<STORAGE_CLASS>|$sc|g" \
    -e "s|<ROOT_SECRET>|$ROOT_SECRET|g" \
  "$SAMPLE_DIR/deploy/gitlab.yaml" | "${KCTL[@]}" apply -f - \
  || die "could not apply deploy/gitlab.yaml."

echo "  waiting for GitLab to become Ready. The single-container image migrates its"
echo "  database and starts its services on a first boot, which takes several minutes."
"${KCTL[@]}" rollout status deploy/gitlab -n "$NAMESPACE" --timeout=1200s \
  || die "GitLab did not become Ready within 20 minutes. Its own log says where it stopped:
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE logs deploy/gitlab --tail=50
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE describe pod -l app=gitlab"

say "setup complete"
cat <<EOF
  Namespace:    $NAMESPACE (labelled $LABEL_KEY=$LABEL_VALUE)
  GitLab:       Deployment gitlab, ClusterIP Service gitlab:8080, volume gitlab-data on $sc
  In-cluster:   $GITLAB_URL   (what the runner and the job pods use)

Next, create the project, mint a runner authentication token and start the runner manager:

  ./scripts/bootstrap-runner.sh

To look at GitLab yourself, forward the ClusterIP Service to your own machine and sign in as
root. Nothing is exposed outside the cluster: there is no Ingress, LoadBalancer or NodePort.

  kubectl --context $KUBE_CONTEXT -n $NAMESPACE port-forward svc/gitlab 8080:8080
  # then open http://localhost:8080 and read the password out of the Secret:
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE get secret $ROOT_SECRET -o go-template='{{index .data "password" | base64decode}}{{"\n"}}'
EOF
