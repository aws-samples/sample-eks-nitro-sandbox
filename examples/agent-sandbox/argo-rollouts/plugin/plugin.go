package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	log "github.com/sirupsen/logrus"

	"github.com/argoproj/argo-rollouts/pkg/apis/rollouts/v1alpha1"
	"github.com/argoproj/argo-rollouts/rollout/steps/plugin/rpc"
	"github.com/argoproj/argo-rollouts/utils/plugin/types"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	k8stypes "k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// The two step names deploy/rollout.yaml uses. Run dispatches on
// RpcStepContext.PluginName. Argo Rollouts validates step-plugin names against
// ^([a-zA-Z0-9\-]+)/([a-zA-Z0-9_\-.]+)$ (utils/config/config.go at v1.10.1) and
// rejects a bare name, so both carry a prefix. That prefix is an opaque string
// Argo Rollouts never resolves: it is NOT a Kubernetes namespace, and it stays
// fixed when the reader overrides NAMESPACE.
const (
	stepTemplatePatch = "eks-nitro-sandbox/sandbox-template-patch"
	stepWarmpoolDrain = "eks-nitro-sandbox/sandbox-warmpool-drain"
)

// Labels the agent-sandbox controller stamps on pool sandboxes at run time.
// These are the SAME labels scripts/drain-pool.sh reads; keeping the plugin
// faithful to the script means reading the exact same witnesses.
//
// labelTemplateHash is defined in agent-sandbox api/v1beta1/sandbox_types.go at
// v1.0.10 as SandboxTemplateHashLabel. The controller computes it over the
// template's SandboxBlueprint (computeSandboxBlueprintHash), not over the pod
// template alone: the deprecated agents.x-k8s.io/sandbox-pod-template-hash is
// the pod-template one. PodTemplate is a field of SandboxBlueprint, so a change
// to a container's env moves this hash. It is set by the controller, so it does
// not appear anywhere in the release manifest.
const (
	labelWarmPoolSandbox = "agents.x-k8s.io/warm-pool-sandbox"
	labelTemplateHash    = "agents.x-k8s.io/sandbox-template-hash"
)

// The CRDs this plugin drives. SandboxWarmPool and SandboxTemplate live in the
// extensions.agents.x-k8s.io group, but the Sandbox objects themselves are in the
// core agents.x-k8s.io group (verified on-cluster: `sandboxes.agents.x-k8s.io`).
var (
	gvrWarmPool = schema.GroupVersionResource{
		Group: "extensions.agents.x-k8s.io", Version: "v1beta1", Resource: "sandboxwarmpools",
	}
	gvrTemplate = schema.GroupVersionResource{
		Group: "extensions.agents.x-k8s.io", Version: "v1beta1", Resource: "sandboxtemplates",
	}
	gvrSandbox = schema.GroupVersionResource{
		Group: "agents.x-k8s.io", Version: "v1beta1", Resource: "sandboxes",
	}
)

// patchConfig is the config block of the sandbox-template-patch step in deploy/rollout.yaml.
type patchConfig struct {
	Namespace string `json:"namespace"`
	Template  string `json:"template"`
	Revision  string `json:"revision"`
}

// drainConfig is the config block of the sandbox-warmpool-drain step in deploy/rollout.yaml.
//
// Revision is what makes the convergence test meaningful. Without it the step can
// only check that the pool agrees with ITSELF on one template hash, which a pool
// still uniformly on the OLD template also satisfies -- exactly the state the drain
// exists to leave behind. With it, each pool sandbox's resolved TEMPLATE_REVISION
// is compared with the revision this rollout is bumping to, which is the same
// condition scripts/drain-pool.sh waits for.
type drainConfig struct {
	Namespace              string `json:"namespace"`
	Pool                   string `json:"pool"`
	Revision               string `json:"revision"`
	WaitForNewTemplateHash bool   `json:"waitForNewTemplateHash"`
	TimeoutSeconds         int    `json:"timeoutSeconds"`
}

// annRestoreReplicas records the replica count a drain must put back, on the pool
// itself, BEFORE the pool is scaled to zero.
//
// The step's own Status is not enough on its own. The controller persists Status
// only after Run returns, so a plugin or controller that dies between the
// scale-to-zero patch landing and that write leaves no state at all: the next
// invocation would see an empty Status and a pool at replicas=0, read that as
// "nothing to drain", and leave the warm capacity stranded at zero for good.
// This annotation is written first and removed only once the pool is scaled
// back, so that window is recoverable.
const annRestoreReplicas = "eks-nitro-sandbox/drain-restore-replicas"

// rpcPlugin is the StepPlugin implementation. It holds a dynamic client built in
// InitPlugin so Run/Terminate/Abort can talk to the extensions CRDs.
type rpcPlugin struct {
	logCtx *log.Entry
	client dynamic.Interface
}

// New returns a StepPlugin. The concrete return type is the interface the RPC
// server injects, mirroring the argo-rollouts step-plugin sample.
func New(logCtx *log.Entry) rpc.StepPlugin {
	return &rpcPlugin{logCtx: logCtx}
}

// InitPlugin runs once at controller startup. It builds an in-cluster client;
// the controller pod's ServiceAccount must be RBAC-authorized on the extensions
// CRDs (see README.md "Register the step plugin on the controller").
func (p *rpcPlugin) InitPlugin() types.RpcError {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return types.RpcError{ErrorString: fmt.Sprintf("in-cluster config: %v", err)}
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return types.RpcError{ErrorString: fmt.Sprintf("dynamic client: %v", err)}
	}
	p.client = dyn
	p.logCtx.Info("InitPlugin: dynamic client ready for extensions.agents.x-k8s.io/v1beta1")
	return types.RpcError{}
}

// Run dispatches on the step name. Both steps are synchronous and idempotent, so
// on success they return PhaseSuccessful; there is no Running/requeue state to
// persist. A failure returns PhaseFailed, which fails the Rollout step (the same
// contract as drain-pool.sh exiting non-zero).
func (p *rpcPlugin) Run(_ *v1alpha1.Rollout, ctx *types.RpcStepContext) (types.RpcStepResult, types.RpcError) {
	if ctx == nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: "nil step context"}
	}
	switch ctx.PluginName {
	case stepTemplatePatch:
		return p.runTemplatePatch(ctx)
	case stepWarmpoolDrain:
		return p.runWarmpoolDrain(ctx)
	default:
		return types.RpcStepResult{}, types.RpcError{
			ErrorString: fmt.Sprintf("unknown step plugin name %q (expected %q or %q)",
				ctx.PluginName, stepTemplatePatch, stepWarmpoolDrain),
		}
	}
}

// runTemplatePatch patches spec.podTemplate.spec.containers[*].env TEMPLATE_REVISION
// on the named SandboxTemplate. This is the deploy action -- the equivalent of
// applying template-v2.yaml -- driven from the canary timeline. Alone it is the
// exact hazard: the pool keeps serving OLD guests until the drain step runs.
func (p *rpcPlugin) runTemplatePatch(ctx *types.RpcStepContext) (types.RpcStepResult, types.RpcError) {
	var cfg patchConfig
	if err := json.Unmarshal(ctx.Config, &cfg); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("unmarshal config: %v", err)}
	}
	if cfg.Namespace == "" || cfg.Template == "" || cfg.Revision == "" {
		return types.RpcStepResult{}, types.RpcError{ErrorString: "template-patch config needs namespace, template and revision"}
	}
	c := context.Background()

	tmpl, err := p.client.Resource(gvrTemplate).Namespace(cfg.Namespace).Get(c, cfg.Template, metav1.GetOptions{})
	if err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("get sandboxtemplate %s/%s: %v", cfg.Namespace, cfg.Template, err)}
	}

	containers, found, err := unstructured.NestedSlice(tmpl.Object, "spec", "podTemplate", "spec", "containers")
	if err != nil || !found || len(containers) == 0 {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("sandboxtemplate %s has no podTemplate containers", cfg.Template)}
	}
	if err := setEnvRevision(containers, cfg.Revision); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: err.Error()}
	}
	if err := unstructured.SetNestedSlice(tmpl.Object, containers, "spec", "podTemplate", "spec", "containers"); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("set containers: %v", err)}
	}
	if _, err := p.client.Resource(gvrTemplate).Namespace(cfg.Namespace).Update(c, tmpl, metav1.UpdateOptions{}); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("update sandboxtemplate %s: %v", cfg.Template, err)}
	}
	p.logCtx.Infof("patched sandboxtemplate %s/%s TEMPLATE_REVISION=%s", cfg.Namespace, cfg.Template, cfg.Revision)
	return successf("patched SandboxTemplate %s to TEMPLATE_REVISION=%s", cfg.Template, cfg.Revision)
}

// setEnvRevision walks each container's env list and sets TEMPLATE_REVISION to
// revision, adding it where absent. Mutates the containers slice in place.
func setEnvRevision(containers []any, revision string) error {
	for i := range containers {
		container, ok := containers[i].(map[string]any)
		if !ok {
			return fmt.Errorf("container %d is not an object", i)
		}
		env, _, _ := unstructured.NestedSlice(container, "env")
		set := false
		for j := range env {
			e, ok := env[j].(map[string]any)
			if !ok {
				continue
			}
			if e["name"] == "TEMPLATE_REVISION" {
				e["value"] = revision
				env[j] = e
				set = true
			}
		}
		if !set {
			env = append(env, map[string]any{"name": "TEMPLATE_REVISION", "value": revision})
		}
		if err := unstructured.SetNestedSlice(container, env, "env"); err != nil {
			return fmt.Errorf("set env on container %d: %w", i, err)
		}
		containers[i] = container
	}
	return nil
}

// drainState is persisted across Run invocations via RpcStepContext.Status. The
// step is NON-BLOCKING: each Run advances one phase and returns PhaseRunning with a
// RequeueAfter until the pool has drained and re-warmed, instead of blocking the
// controller's RPC for the whole drain. Persisting Want lets Abort/Terminate
// restore the pool if the rollout is interrupted after scale-to-0 but before
// scale-back. Deadline (unix seconds) bounds the whole operation like
// drain-pool.sh's timeout, without a blocking sleep.
type drainState struct {
	Phase    string `json:"phase"`    // "" -> "draining" -> "rewarming"
	Want     int64  `json:"want"`     // replica count to restore
	Deadline int64  `json:"deadline"` // unix seconds; fail past this
}

// requeueInterval is how long the controller waits before calling Run again while
// the drain is in a Running phase. Argo Rollouts ignores a RequeueAfter <= its
// minRequeueDuration (10s) and falls back to 30s, so this is set above that floor
// to be honored; the drain is not latency-critical, ~15s polling is plenty.
const requeueInterval = 15 * time.Second

// runWarmpoolDrain performs drain-pool.sh's operations against the SandboxWarmPool
// as a non-blocking state machine: capture the target and scale to 0, wait for the
// pool to drain, scale back, then wait for readyReplicas with a consistent non-empty
// template-hash across pool sandboxes. Idempotent -- a pool already at the target
// converges on the first calls. Transient client errors return Running (the
// controller requeues), matching drain-pool.sh's tolerance of kubectl blips rather
// than failing the whole step on one apiserver hiccup.
func (p *rpcPlugin) runWarmpoolDrain(ctx *types.RpcStepContext) (types.RpcStepResult, types.RpcError) {
	var cfg drainConfig
	if err := json.Unmarshal(ctx.Config, &cfg); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("unmarshal config: %v", err)}
	}
	if cfg.Namespace == "" || cfg.Pool == "" {
		return types.RpcStepResult{}, types.RpcError{ErrorString: "drain config needs namespace and pool"}
	}
	total := cfg.TimeoutSeconds
	if total <= 0 {
		total = 600 // matches drain-pool.sh's default overall bound
	}

	var st drainState
	if len(ctx.Status) > 0 {
		if err := json.Unmarshal(ctx.Status, &st); err != nil {
			return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("unmarshal status: %v", err)}
		}
	}

	c := context.Background()
	pools := p.client.Resource(gvrWarmPool).Namespace(cfg.Namespace)
	sandboxes := p.client.Resource(gvrSandbox).Namespace(cfg.Namespace)

	// Enforce the deadline BEFORE the (retryable) Get so a persistently unreachable
	// apiserver cannot hang the step forever: once started, past the deadline we fail
	// and restore. failAndRestore scales the pool back to Want first, because the
	// controller does NOT invoke Abort/Terminate on a Failed step -- so this is the
	// only place a timed-out drain can un-strand a pool it left at 0.
	if st.Phase != "" && time.Now().Unix() > st.Deadline {
		return p.failAndRestore(st, pools, cfg.Pool, st.Want,
			"pool %s did not converge within %ds (phase=%s)", cfg.Pool, total, st.Phase)
	}

	pool, err := pools.Get(c, cfg.Pool, metav1.GetOptions{})
	if err != nil {
		p.logCtx.Warnf("get pool %s (will retry): %v", cfg.Pool, err)
		return runningf(st, "waiting to read sandboxwarmpool %s", cfg.Pool)
	}

	// First call: capture the restore target and scale to 0.
	if st.Phase == "" {
		if poolSelectorFrom(pool) == "" {
			return runningf(st, "waiting for sandboxwarmpool %s status.selector", cfg.Pool)
		}
		want, _, _ := unstructured.NestedInt64(pool.Object, "spec", "replicas")
		if want == 0 {
			// A pool at replicas=0 with no state of our own is ambiguous: either
			// there is genuinely nothing to drain, or an earlier attempt scaled it
			// to zero and died before its Status was persisted. The annotation is
			// what tells those two apart, so never report success without asking.
			if saved := restoreAnnotation(pool); saved > 0 {
				p.logCtx.Warnf("pool %s is at 0 with a restore target of %d recorded; an earlier drain was interrupted, recovering", cfg.Pool, saved)
				if err := patchReplicas(c, pools, cfg.Pool, saved); err != nil {
					p.logCtx.Warnf("restore %s to %d (will retry): %v", cfg.Pool, saved, err)
					return runningf(st, "recovering an interrupted drain: restoring %s to %d", cfg.Pool, saved)
				}
				st.Phase = "rewarming"
				st.Want = saved
				st.Deadline = time.Now().Unix() + int64(total)
				return runningf(st, "recovered an interrupted drain: %s restored to %d", cfg.Pool, saved)
			}
			p.logCtx.Info("pool spec.replicas already 0 and no restore target recorded; nothing to drain")
			return successf("pool %s already at replicas=0; nothing to drain", cfg.Pool)
		}
		// Record the restore target BEFORE scaling anything, so an interruption
		// between the two is recoverable rather than permanent.
		if err := setRestoreAnnotation(c, pools, cfg.Pool, want); err != nil {
			p.logCtx.Warnf("record the restore target on %s (will retry): %v", cfg.Pool, err)
			return runningf(st, "recording the restore target on %s", cfg.Pool)
		}
		if err := patchReplicas(c, pools, cfg.Pool, 0); err != nil {
			p.logCtx.Warnf("scale %s to 0 (will retry): %v", cfg.Pool, err)
			return runningf(st, "retrying scale-to-0 on %s", cfg.Pool)
		}
		st.Phase = "draining"
		st.Want = want
		st.Deadline = time.Now().Unix() + int64(total)
		p.logCtx.Infof("pool %s: scaled to 0 (restore target=%d), draining", cfg.Pool, want)
		return runningf(st, "pool %s scaling to 0", cfg.Pool)
	}

	poolSelector := poolSelectorFrom(pool)
	if poolSelector == "" {
		return runningf(st, "waiting for sandboxwarmpool %s status.selector", cfg.Pool)
	}

	switch st.Phase {
	case "draining":
		// A pool sandbox is "still there" if it appears in the selector at all --
		// Terminating counts, exactly as drain-pool.sh treats it.
		list, err := sandboxes.List(c, metav1.ListOptions{LabelSelector: poolSelector})
		if err != nil {
			p.logCtx.Warnf("list pool sandboxes (will retry): %v", err)
			return runningf(st, "listing pool sandboxes")
		}
		if len(list.Items) > 0 {
			return runningf(st, "draining: %d pool sandbox(es) still present", len(list.Items))
		}
		if err := patchReplicas(c, pools, cfg.Pool, st.Want); err != nil {
			p.logCtx.Warnf("scale %s back to %d (will retry): %v", cfg.Pool, st.Want, err)
			return runningf(st, "retrying scale-back on %s", cfg.Pool)
		}
		// The pool is back at its target, so the recovery annotation has done its
		// job. Clearing it is best effort: a leftover annotation on a pool that is
		// NOT at zero is inert, because it is only ever read when replicas==0.
		if err := clearRestoreAnnotation(c, pools, cfg.Pool); err != nil {
			p.logCtx.Warnf("could not clear %s on %s: %v", annRestoreReplicas, cfg.Pool, err)
		}
		st.Phase = "rewarming"
		p.logCtx.Infof("pool %s: drained, scaled back to %d, re-warming", cfg.Pool, st.Want)
		return runningf(st, "pool %s scaling back to %d", cfg.Pool, st.Want)

	case "rewarming":
		ready, _, _ := unstructured.NestedInt64(pool.Object, "status", "readyReplicas")
		if ready != st.Want {
			return runningf(st, "re-warming: readyReplicas=%d/%d", ready, st.Want)
		}
		if !cfg.WaitForNewTemplateHash {
			if err := clearRestoreAnnotation(c, pools, cfg.Pool); err != nil {
				p.logCtx.Warnf("could not clear %s on %s: %v", annRestoreReplicas, cfg.Pool, err)
			}
			p.logCtx.Infof("pool %s re-warmed (readyReplicas=%d)", cfg.Pool, st.Want)
			return successf("pool %s re-warmed (readyReplicas=%d)", cfg.Pool, st.Want)
		}
		// Convergence is a statement about EVERY pool sandbox, not about the ones
		// that happened to carry a label. A sandbox missing from the list, or one
		// with no hash yet, is one that has not converged: dropping either would
		// let a half-replaced pool pass, and a claim in that window could still
		// adopt a pod from the old revision.
		hash, why, err := poolConverged(c, sandboxes, poolSelector, st.Want, cfg.Revision)
		if err != nil {
			p.logCtx.Warnf("read the pool's sandboxes (will retry): %v", err)
			return runningf(st, "reading the pool's sandboxes")
		}
		if why != "" {
			return runningf(st, "re-warming: readyReplicas=%d/%d, %s", ready, st.Want, why)
		}
		if err := clearRestoreAnnotation(c, pools, cfg.Pool); err != nil {
			p.logCtx.Warnf("could not clear %s on %s: %v", annRestoreReplicas, cfg.Pool, err)
		}
		p.logCtx.Infof("pool %s re-warmed at template-hash=%s", cfg.Pool, hash)
		return successf("pool %s re-warmed at template-hash=%s", cfg.Pool, hash)

	default:
		return p.failAndRestore(st, pools, cfg.Pool, st.Want, "pool %s in unknown drain phase %q", cfg.Pool, st.Phase)
	}
}

// poolConverged reports whether the pool has fully re-warmed. It returns the
// shared template hash when it has, or a reason string when it has not; an error
// means the reading itself failed, and the caller must retry rather than conclude
// anything from it.
//
// Every condition is "all of them", never "the ones that could be read":
//   - exactly want sandboxes are selected, so a half-replaced pool is not converged;
//   - every one carries a non-empty template hash, and they all agree;
//   - when revision is set, every one resolves TEMPLATE_REVISION to it. Without
//     this last test the step could only check that the pool agrees with itself,
//     which a pool still uniformly on the OLD template also satisfies.
func poolConverged(c context.Context, r dynamic.ResourceInterface, selector string, want int64, revision string) (string, string, error) {
	list, err := r.List(c, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return "", "", err
	}
	if int64(len(list.Items)) != want {
		return "", fmt.Sprintf("%d of %d pool sandbox(es) present", len(list.Items), want), nil
	}
	hash := ""
	for i := range list.Items {
		item := &list.Items[i]
		h := item.GetLabels()[labelTemplateHash]
		if h == "" {
			return "", fmt.Sprintf("sandbox %s carries no %s yet", item.GetName(), labelTemplateHash), nil
		}
		if hash == "" {
			hash = h
		} else if h != hash {
			return "", fmt.Sprintf("sandboxes disagree on %s (%s and %s)", labelTemplateHash, hash, h), nil
		}
		if revision != "" {
			if got := sandboxRevision(item); got != revision {
				return "", fmt.Sprintf("sandbox %s booted at TEMPLATE_REVISION=%q, want %q", item.GetName(), got, revision), nil
			}
		}
	}
	if hash == "" {
		return "", "the pool has no sandboxes", nil
	}
	return hash, "", nil
}

// sandboxRevision reads TEMPLATE_REVISION out of a Sandbox's own resolved
// podTemplate, which records what that pod BOOTED with rather than what the
// template says now. It returns "" when the marker is absent, which callers
// treat as "not converged" and never as a match.
func sandboxRevision(item *unstructured.Unstructured) string {
	containers, found, err := unstructured.NestedSlice(item.Object, "spec", "podTemplate", "spec", "containers")
	if err != nil || !found {
		return ""
	}
	for _, raw := range containers {
		container, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		env, _, _ := unstructured.NestedSlice(container, "env")
		for _, e := range env {
			entry, ok := e.(map[string]any)
			if !ok {
				continue
			}
			if entry["name"] == "TEMPLATE_REVISION" {
				if v, ok := entry["value"].(string); ok {
					return v
				}
			}
		}
	}
	return ""
}

// restoreAnnotation reads the recorded restore target off the pool. It returns 0
// when the annotation is absent or unparsable, which callers treat as "no target
// recorded" rather than as "restore to zero".
func restoreAnnotation(pool *unstructured.Unstructured) int64 {
	v := pool.GetAnnotations()[annRestoreReplicas]
	if v == "" {
		return 0
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func setRestoreAnnotation(c context.Context, r dynamic.ResourceInterface, name string, n int64) error {
	body := []byte(fmt.Sprintf(`{"metadata":{"annotations":{%q:%q}}}`, annRestoreReplicas, strconv.FormatInt(n, 10)))
	_, err := r.Patch(c, name, k8stypes.MergePatchType, body, metav1.PatchOptions{})
	return err
}

func clearRestoreAnnotation(c context.Context, r dynamic.ResourceInterface, name string) error {
	body := []byte(fmt.Sprintf(`{"metadata":{"annotations":{%q:null}}}`, annRestoreReplicas))
	_, err := r.Patch(c, name, k8stypes.MergePatchType, body, metav1.PatchOptions{})
	return err
}

// failAndRestore puts the pool back to want before failing the step. The
// controller does NOT call Abort or Terminate on a step that has already failed,
// so this is the last chance to un-strand warm capacity.
//
// If the restore itself fails it returns Running and keeps the state, so the
// controller calls back and the restore is retried. Failing terminally there
// would leave the pool at zero with nothing left to put it back, which is the one
// outcome the drain must never produce: a pool at zero serves no claims at all,
// which is worse than serving stale ones. The retry is bounded by the Rollout's
// own progress deadline rather than by this plugin.
func (p *rpcPlugin) failAndRestore(st drainState, pools dynamic.ResourceInterface, pool string, want int64, format string, a ...any) (types.RpcStepResult, types.RpcError) {
	c := context.Background()
	if want > 0 {
		if err := patchReplicas(c, pools, pool, want); err != nil {
			p.logCtx.Warnf("failAndRestore: could not restore %s to replicas=%d, staying Running to retry: %v", pool, want, err)
			return runningf(st, "retrying the restore of %s to replicas=%d before failing the step", pool, want)
		}
		p.logCtx.Infof("failAndRestore: restored %s to replicas=%d before failing", pool, want)
		if err := clearRestoreAnnotation(c, pools, pool); err != nil {
			p.logCtx.Warnf("could not clear %s on %s: %v", annRestoreReplicas, pool, err)
		}
	}
	return failf(format, a...)
}

// Terminate unwinds an interrupted drain: if the pool was scaled to 0 but not yet
// scaled back, restore its replica count so a stopped step never strands warm
// capacity at 0. The template-patch step carries no Status, so this is a no-op there.
func (p *rpcPlugin) Terminate(_ *v1alpha1.Rollout, ctx *types.RpcStepContext) (types.RpcStepResult, types.RpcError) {
	return p.restoreIfDraining(ctx, "terminate")
}

// Abort mirrors Terminate: restore the pool if it was left mid-drain. Reverting a
// completed template bump or a completed drain is a rollout concern (re-run the
// steps at the prior revision), not something the plugin undoes implicitly.
func (p *rpcPlugin) Abort(_ *v1alpha1.Rollout, ctx *types.RpcStepContext) (types.RpcStepResult, types.RpcError) {
	return p.restoreIfDraining(ctx, "abort")
}

// restoreIfDraining scales the pool back to its captured replica count if the drain
// was interrupted in the "draining" phase (after scale-to-0, before scale-back).
// "rewarming" already scaled the pool back, so no unwind is needed there.
// Nothing here reports a successful unwind that it could not establish. Every
// path that cannot determine whether the pool is stranded returns an RPC error
// instead, because "no drain state to unwind" on a pool sitting at zero reads as
// "all fine" while the warm capacity stays gone.
func (p *rpcPlugin) restoreIfDraining(ctx *types.RpcStepContext, op string) (types.RpcStepResult, types.RpcError) {
	if ctx == nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
			"%s: nil step context, so whether a drain left the pool scaled to zero could not be determined", op)}
	}
	c := context.Background()
	var cfg drainConfig
	cfgOK := json.Unmarshal(ctx.Config, &cfg) == nil && cfg.Namespace != "" && cfg.Pool != ""

	// No status at all. Either the drain never got as far as scaling the pool, or
	// it died before its state was persisted. The second case is the dangerous
	// one, so ask the pool itself rather than assuming the first.
	if len(ctx.Status) == 0 {
		if !cfgOK || p.client == nil {
			return successf("%s: no drain state and no pool reference; nothing to unwind", op)
		}
		pools := p.client.Resource(gvrWarmPool).Namespace(cfg.Namespace)
		pool, err := pools.Get(c, cfg.Pool, metav1.GetOptions{})
		if err != nil {
			return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
				"%s: sandboxwarmpool %s/%s could not be read, so whether a drain left it at zero could not be determined: %v",
				op, cfg.Namespace, cfg.Pool, err)}
		}
		replicas, _, _ := unstructured.NestedInt64(pool.Object, "spec", "replicas")
		saved := restoreAnnotation(pool)
		if replicas != 0 || saved <= 0 {
			return successf("%s: no drain state to unwind (spec.replicas=%d)", op, replicas)
		}
		if err := patchReplicas(c, pools, cfg.Pool, saved); err != nil {
			return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
				"%s: restore replicas=%d on %s: %v", op, saved, cfg.Pool, err)}
		}
		if err := clearRestoreAnnotation(c, pools, cfg.Pool); err != nil {
			p.logCtx.Warnf("could not clear %s on %s: %v", annRestoreReplicas, cfg.Pool, err)
		}
		p.logCtx.Infof("%s: restored pool %s to replicas=%d from its recorded target", op, cfg.Pool, saved)
		return successf("%s: restored pool %s to replicas=%d from its recorded target", op, cfg.Pool, saved)
	}

	var st drainState
	if err := json.Unmarshal(ctx.Status, &st); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
			"%s: the drain's own state could not be parsed (%v), so whether the pool is stranded at spec.replicas=0 could not be determined; check the pool and its %s annotation by hand",
			op, err, annRestoreReplicas)}
	}
	if st.Phase != "draining" || st.Want <= 0 {
		return successf("%s: no unwind needed (phase=%s)", op, st.Phase)
	}
	// Past here the pool WAS scaled to zero and has not been scaled back, so an
	// unwind is owed and anything that stops it is an error, never a success.
	if !cfgOK {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
			"%s: the drain was interrupted after scaling the pool to zero but its config names no pool, so the pool could not be restored to replicas=%d", op, st.Want)}
	}
	if p.client == nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
			"%s: no Kubernetes client, so pool %s could not be restored to replicas=%d", op, cfg.Pool, st.Want)}
	}
	pools := p.client.Resource(gvrWarmPool).Namespace(cfg.Namespace)
	if err := patchReplicas(c, pools, cfg.Pool, st.Want); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf(
			"%s: restore replicas=%d on %s: %v", op, st.Want, cfg.Pool, err)}
	}
	if err := clearRestoreAnnotation(c, pools, cfg.Pool); err != nil {
		p.logCtx.Warnf("could not clear %s on %s: %v", annRestoreReplicas, cfg.Pool, err)
	}
	p.logCtx.Infof("%s: restored pool %s to replicas=%d", op, cfg.Pool, st.Want)
	return successf("%s: restored pool %s to replicas=%d", op, cfg.Pool, st.Want)
}

func (p *rpcPlugin) Type() string { return "sandbox-warmpool" }

// --- helpers ---------------------------------------------------------------

func patchReplicas(c context.Context, r dynamic.ResourceInterface, name string, n int64) error {
	body := []byte(fmt.Sprintf(`{"spec":{"replicas":%d}}`, n))
	if _, err := r.Patch(c, name, k8stypes.MergePatchType, body, metav1.PatchOptions{}); err != nil {
		return fmt.Errorf("patch replicas=%d on %s: %w", n, name, err)
	}
	return nil
}

// poolSelectorFrom builds the label selector for a pool's sandboxes from its
// status.selector (agents.x-k8s.io/warm-pool-sandbox=<NameHash(pool)>). It returns
// "" if the selector is absent or not yet in the expected key=value form -- callers
// treat "" as "not ready", never as "matches nothing", so a malformed selector can
// never be mistaken for an empty pool.
func poolSelectorFrom(pool *unstructured.Unstructured) string {
	selector, found, _ := unstructured.NestedString(pool.Object, "status", "selector")
	if !found || !strings.Contains(selector, "=") {
		return ""
	}
	hash := selector[strings.Index(selector, "=")+1:]
	if hash == "" {
		return ""
	}
	return fmt.Sprintf("%s=%s", labelWarmPoolSandbox, hash)
}

func runningf(st drainState, format string, a ...any) (types.RpcStepResult, types.RpcError) {
	raw, _ := json.Marshal(st)
	return types.RpcStepResult{
		Phase:        types.PhaseRunning,
		Message:      fmt.Sprintf(format, a...),
		RequeueAfter: requeueInterval,
		Status:       raw,
	}, types.RpcError{}
}

func successf(format string, a ...any) (types.RpcStepResult, types.RpcError) {
	return types.RpcStepResult{Phase: types.PhaseSuccessful, Message: fmt.Sprintf(format, a...)}, types.RpcError{}
}

func failf(format string, a ...any) (types.RpcStepResult, types.RpcError) {
	return types.RpcStepResult{Phase: types.PhaseFailed, Message: fmt.Sprintf(format, a...)}, types.RpcError{}
}
