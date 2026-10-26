#!/usr/bin/env bash
# Build the step plugin and register it on the Argo Rollouts controller.
#
#   ./scripts/register-step-plugin.sh          # plan: print what apply would do, change nothing
#   ./scripts/register-step-plugin.sh apply    # do it
#
# THIS IS THE PAGE'S READER STEP, NOT PART OF setup.sh, and it is the one script
# here that writes to shared, cluster-wide state. Registering a step plugin means
# a key in the controller's own argo-rollouts-config ConfigMap, a ClusterRole
# giving the controller access to the agent-sandbox CRDs, and an initContainer on
# the controller's Deployment that stages the binary. All three change a
# controller other workloads on the cluster may use, which is why nothing here
# happens without an explicit `apply`, and why scripts/setup.sh only ever reads
# them.
#
# It refuses to touch a registration it does not recognise: if the ConfigMap
# already registers step plugins that are not this sample's, it stops and says
# what it found rather than writing over somebody else's controller.
#
# What apply does, in order:
#   1. check Argo Rollouts is installed and the existing registration is ours
#   2. create or adopt an ECR repository for the plugin image, tagged
#      ManagedBy=argo-rollouts
#   3. build the plugin image for the controller node's architecture and push it
#   4. read the built binary's sha256, which the controller verifies
#   5. create or merge the stepPlugins key into argo-rollouts-config, leaving
#      every other key in it alone
#   6. apply the ClusterRole and ClusterRoleBinding
#   7. patch the controller Deployment with the initContainer that stages the
#      binary, and wait for it to come back up
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

ACTION="${1:-plan}"
[[ "$ACTION" == plan || "$ACTION" == apply ]] || die "usage: $0 [plan|apply]"

require_commands kubectl docker aws jq sed awk grep sha256sum
show_context

# ---------------------------------------------------------------------------
# Readings the plan and the apply both need.
# ---------------------------------------------------------------------------
require_argo_rollouts

# The architecture of the node the CONTROLLER runs on, not of this machine: the
# binary is exec'd by the controller, so a build on an arm64 laptop still has to
# produce a binary for the controller's node.
ctrl_pod="$(kc_cluster -n "$ARGO_NAMESPACE" get pods -l app.kubernetes.io/name=argo-rollouts \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || ctrl_pod=""
[[ -n "$ctrl_pod" ]] || die "could not find the Argo Rollouts controller pod in namespace $ARGO_NAMESPACE"
ctrl_node="$(kc_cluster -n "$ARGO_NAMESPACE" get pod "$ctrl_pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" || ctrl_node=""
[[ -n "$ctrl_node" ]] || die "could not read which node controller pod $ctrl_pod runs on"
ctrl_arch="$(kc_cluster get node "$ctrl_node" -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null)" || ctrl_arch=""
[[ "$ctrl_arch" == amd64 || "$ctrl_arch" == arm64 ]] \
  || die "the Argo Rollouts controller node $ctrl_node reports architecture '${ctrl_arch:-<unreadable>}'; expected amd64 or arm64, so the plugin could not be built for it"

# The existing registration, if any. This is the guard that keeps the script off
# somebody else's controller: a failed read stops the run, and a registration
# holding names that are not ours stops it too.
reg_rc=0
registered="$(registered_step_plugins)" || reg_rc=$?
case $reg_rc in
  0) ;;   # the ConfigMap is there and was read; it may hold nothing
  1) registered="" ;;   # no ConfigMap yet, which is the ordinary first run
  2) die "could not read configmap argo-rollouts-config in namespace $ARGO_NAMESPACE, so the existing step-plugin registration could not be determined; stopping rather than write over it" ;;
esac
foreign=""
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  [[ "$name" == "$STEP_PATCH" || "$name" == "$STEP_DRAIN" ]] && continue
  foreign+=" $name"
done <<<"$registered"
[[ -z "$foreign" ]] || die "the Argo Rollouts controller in namespace $ARGO_NAMESPACE already registers step plugins that are not this sample's:$foreign
Adding to that registration would change a controller those workloads depend on. This is a
question for whoever owns that install, not something this script will decide. Run this
sample on a cluster whose Argo Rollouts install you own."

# Staging the binary needs an fsGroup on the controller pod so the emptyDir is
# writable by the non-root initContainer. If the install already sets a DIFFERENT
# one, that is a setting its owner chose: overwriting it would change how the
# controller runs, and the clean up could not put it back either. Stop and say
# what was found.
existing_fsgroup="$(kc_cluster -n "$ARGO_NAMESPACE" get deploy argo-rollouts \
  -o jsonpath='{.spec.template.spec.securityContext.fsGroup}' 2>/dev/null)" || existing_fsgroup="?"
[[ "$existing_fsgroup" == "?" ]] \
  && die "could not read the Argo Rollouts Deployment's pod securityContext, so whether staging the binary would change it could not be determined"
[[ -z "$existing_fsgroup" || "$existing_fsgroup" == "999" ]] \
  || die "deployment $ARGO_NAMESPACE/argo-rollouts already sets securityContext.fsGroup=$existing_fsgroup.
Staging the plugin binary needs fsGroup 999 so the non-root initContainer can write the
shared volume, and changing an fsGroup its owner chose would change how that controller runs.
This is a question for whoever owns that install. Run this sample on a cluster whose Argo
Rollouts install you own."

: "${AWS_REGION:?set AWS_REGION in .env (the Region your ECR repository should live in)}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "could not read the AWS account; check your credentials"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${PLUGIN_REPO}:${ARGO_ROLLOUTS_VERSION}"
REPO_ARN="arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${PLUGIN_REPO}"

if [[ "$ACTION" == plan ]]; then
  cat <<EOF

PLAN. Nothing below has been done; run './scripts/register-step-plugin.sh apply' to do it.

  Argo Rollouts   namespace $ARGO_NAMESPACE, controller pod $ctrl_pod on node $ctrl_node ($ctrl_arch)
  registered now  ${registered:-<nothing>}
  ECR repository  $PLUGIN_REPO in $AWS_REGION (account $ACCOUNT_ID), tagged ManagedBy=$MANAGED_BY
  plugin image    $IMAGE

  1. create or adopt the ECR repository above
  2. docker build plugin/ for $ctrl_arch and push it
  3. read the built binary's sha256
  4. set data.stepPlugins on configmap $ARGO_NAMESPACE/argo-rollouts-config to register
       $STEP_PATCH
       $STEP_DRAIN
     (created when absent; otherwise ONLY this key is merged, other keys are left alone)
  5. apply clusterrole and clusterrolebinding argo-rollouts-sandbox-warmpool
  6. patch deployment $ARGO_NAMESPACE/argo-rollouts with an initContainer that stages the
     binary into an emptyDir at /plugins, and wait for it to roll out

  Steps 4, 5 and 6 CHANGE SHARED STATE: the controller's own ConfigMap, a cluster-scoped
  ClusterRole, and the controller's Deployment. The clean up removes the ClusterRole and
  ClusterRoleBinding; the page's clean up section has the commands to undo the ConfigMap key
  and the Deployment patch, and to remove Argo Rollouts if nothing else on the cluster uses it.
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

step "1/6 the ECR repository $PLUGIN_REPO"
# A repository that exists is reused only when it carries this sample's tag, so a
# repository of the same name that belongs to something else is never pushed to.
# A read that fails stops the run rather than being taken for "absent".
repo_out=""
if repo_out="$(aws ecr describe-repositories --repository-names "$PLUGIN_REPO" \
                 --region "$AWS_REGION" 2>&1)"; then
  tags_out="$(aws ecr list-tags-for-resource --resource-arn "$REPO_ARN" --region "$AWS_REGION" 2>&1)" \
    || die "ECR repository $PLUGIN_REPO exists but its tags could not be read, so whether it is this sample's could not be determined:
$tags_out"
  owned="$(printf '%s' "$tags_out" | jq -r --arg m "$MANAGED_BY" 'any(.tags[]?; .Key=="ManagedBy" and .Value==$m)')"
  [[ "$owned" == "true" ]] || die "ECR repository $PLUGIN_REPO exists but is not tagged ManagedBy=$MANAGED_BY, so it is not this sample's; refusing to push to it. Set PLUGIN_REPO in .env to a name of your own."
  echo "  reusing $PLUGIN_REPO (tagged ManagedBy=$MANAGED_BY)"
else
  case "$repo_out" in
    *RepositoryNotFoundException*)
      aws ecr create-repository --repository-name "$PLUGIN_REPO" --region "$AWS_REGION" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 \
        --tags Key=ManagedBy,Value="$MANAGED_BY" >/dev/null \
        || die "could not create the ECR repository $PLUGIN_REPO"
      echo "  created $PLUGIN_REPO, tagged ManagedBy=$MANAGED_BY" ;;
    *) die "could not read ECR repository $PLUGIN_REPO (the call failed, which is not a report that it is missing):
$repo_out" ;;
  esac
fi

step "2/6 build the plugin for $ctrl_arch and push it"
# The password goes in on standard input, never on the command line.
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
  || die "could not log in to $REGISTRY"
# GOPROXY and GOSUMDB default to Go's own values inside the Dockerfile, so the
# module proxy and the checksum database verify every dependency. Pass them here
# only on a network that cannot reach proxy.golang.org.
build_args=(--build-arg "TARGETARCH=$ctrl_arch")
[[ -n "${GOPROXY:-}" ]] && build_args+=(--build-arg "GOPROXY=$GOPROXY")
[[ -n "${GOSUMDB:-}" ]] && build_args+=(--build-arg "GOSUMDB=$GOSUMDB")
docker build "${build_args[@]}" -t "$IMAGE" "$SAMPLE_DIR/plugin" \
  || die "the plugin build failed"
docker push "$IMAGE" >/dev/null || die "could not push $IMAGE"
echo "  pushed $IMAGE"

step "3/6 the built binary's sha256"
# Taken from the image that was just pushed, so the hash the controller verifies
# is the hash of the binary it will actually load.
cid="$(docker create "$IMAGE")" || die "could not create a container from $IMAGE to read the binary"
docker cp "$cid:/bin/$PLUGIN_BIN" "$tmp_dir/$PLUGIN_BIN" >/dev/null \
  || { docker rm "$cid" >/dev/null 2>&1 || true; die "could not copy the binary out of $IMAGE"; }
docker rm "$cid" >/dev/null 2>&1 || true
PLUGIN_SHA256="$(sha256sum "$tmp_dir/$PLUGIN_BIN" | cut -d' ' -f1)"
[[ ${#PLUGIN_SHA256} -eq 64 ]] || die "could not compute the plugin binary's sha256"
echo "  sha256 $PLUGIN_SHA256"

step "4/6 register the plugin in configmap argo-rollouts-config"
sed -e "s/__ARGO_NAMESPACE__/$ARGO_NAMESPACE/g" -e "s/__PLUGIN_SHA256__/$PLUGIN_SHA256/g" \
  "$SAMPLE_DIR/deploy/step-plugin-config.yaml" > "$tmp_dir/config.yaml"
# The value comes out of the rendered manifest rather than being written again
# here, so the file the page shows is the registration that is applied. The
# pattern is anchored at the key and takes only the block indented under it.
step_plugins="$(awk '
  /^[[:space:]]*stepPlugins:[[:space:]]*\|[[:space:]]*$/ { inblock = 1; next }
  inblock {
    if ($0 ~ /^    /) { sub(/^    /, ""); print; next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    inblock = 0
  }
' "$tmp_dir/config.yaml")"
printf '%s' "$step_plugins" | grep -Fq "$STEP_PATCH" \
  || die "could not read the stepPlugins block out of deploy/step-plugin-config.yaml"
printf '%s' "$step_plugins" | grep -Fq "$PLUGIN_SHA256" \
  || die "the stepPlugins block read from the manifest does not carry the sha256 that was just computed"

cm_rc=0
resource_exists kc_cluster -n "$ARGO_NAMESPACE" configmap argo-rollouts-config || cm_rc=$?
case $cm_rc in
  1) kc_cluster create -f "$tmp_dir/config.yaml" >/dev/null \
       || die "could not create configmap argo-rollouts-config"
     echo "  created configmap argo-rollouts-config with this sample's two step plugins" ;;
  2) die "could not read configmap argo-rollouts-config; stopping rather than write over it" ;;
  0) # Merge ONLY this key. An apply would reconcile away any other key the
     # ConfigMap holds, such as trafficRouterPlugins, which other workloads use.
     patch="$(jq -n --arg v "$step_plugins" '{data: {stepPlugins: $v}}')"
     kc_cluster -n "$ARGO_NAMESPACE" patch configmap argo-rollouts-config \
       --type=merge -p "$patch" >/dev/null \
       || die "could not merge the stepPlugins key into configmap argo-rollouts-config"
     echo "  merged the stepPlugins key into the existing configmap, leaving its other keys alone" ;;
esac

step "5/6 the ClusterRole the plugin acts with"
sed -e "s/__ARGO_NAMESPACE__/$ARGO_NAMESPACE/g" "$SAMPLE_DIR/deploy/step-plugin-rbac.yaml" \
  | kc_cluster apply -f -

step "6/6 stage the binary on the controller pod"
# A strategic merge patch on a Deployment merges initContainers, volumes and
# volumeMounts BY NAME, so another initContainer or volume already on the
# controller is kept rather than replaced.
#
# The controller pod runs as non-root, so the initContainer has to run as a
# non-root uid too, and fsGroup makes the emptyDir group-writable by it so `cp`
# can stage the binary. The binary keeps its 0755 mode, so the controller can
# read it whatever uid it runs as.
read -r -d '' deploy_patch <<YAML || true
spec:
  template:
    spec:
      securityContext:
        fsGroup: 999
      volumes:
        - name: plugins
          emptyDir: {}
      initContainers:
        - name: copy-sandbox-warmpool-plugin
          image: $IMAGE
          command: ["cp", "/bin/$PLUGIN_BIN", "$PLUGIN_PATH"]
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
            runAsGroup: 999
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: plugins
              mountPath: /plugins
      containers:
        - name: argo-rollouts
          volumeMounts:
            - name: plugins
              mountPath: /plugins
YAML
kc_cluster -n "$ARGO_NAMESPACE" patch deployment argo-rollouts --type=strategic -p "$deploy_patch" \
  || die "could not patch deployment argo-rollouts to stage the plugin binary"
kc_cluster -n "$ARGO_NAMESPACE" rollout status deploy/argo-rollouts --timeout=180s \
  || die "the Argo Rollouts controller did not come back up after the patch. Check 'kubectl -n $ARGO_NAMESPACE get pods' and 'kubectl -n $ARGO_NAMESPACE describe deploy argo-rollouts'"

echo
require_step_plugin
echo
echo "The step plugin is registered. Drive the rollout:  ./scripts/run-rollout.sh"
