package main

import (
	"context"
	"encoding/json"
	"fmt"
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
// v1.0.6 as SandboxTemplateHashLabel. The controller computes it over the
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
type drainConfig struct {
	Namespace              string `json:"namespace"`
	Pool                   string `json:"pool"`
	WaitForNewTemplateHash bool   `json:"waitForNewTemplateHash"`
	TimeoutSeconds         int    `json:"timeoutSeconds"`
}

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
		return p.failAndRestore(pools, cfg.Pool, st.Want,
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
			p.logCtx.Info("pool spec.replicas already 0; nothing to drain")
			return successf("pool %s already at replicas=0; nothing to drain", cfg.Pool)
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
		st.Phase = "rewarming"
		p.logCtx.Infof("pool %s: drained, scaled back to %d, re-warming", cfg.Pool, st.Want)
		return runningf(st, "pool %s scaling back to %d", cfg.Pool, st.Want)

	case "rewarming":
		ready, _, _ := unstructured.NestedInt64(pool.Object, "status", "readyReplicas")
		if ready != st.Want {
			return runningf(st, "re-warming: readyReplicas=%d/%d", ready, st.Want)
		}
		if !cfg.WaitForNewTemplateHash {
			p.logCtx.Infof("pool %s re-warmed (readyReplicas=%d)", cfg.Pool, st.Want)
			return successf("pool %s re-warmed (readyReplicas=%d)", cfg.Pool, st.Want)
		}
		hashes, err := distinctTemplateHashes(c, sandboxes, poolSelector)
		if err != nil {
			p.logCtx.Warnf("read pool template-hashes (will retry): %v", err)
			return runningf(st, "reading pool template-hashes")
		}
		// The convergence condition: readyReplicas==want AND one consistent
		// non-empty hash. It does NOT require the hash to differ from pre-drain --
		// an already-converged pool is a valid no-op reboot (see drain-pool.sh).
		if len(hashes) != 1 {
			return runningf(st, "re-warming: readyReplicas=%d/%d, distinct template-hashes=%v", ready, st.Want, hashes)
		}
		p.logCtx.Infof("pool %s re-warmed at template-hash=%s", cfg.Pool, hashes[0])
		return successf("pool %s re-warmed at template-hash=%s", cfg.Pool, hashes[0])

	default:
		return p.failAndRestore(pools, cfg.Pool, st.Want, "pool %s in unknown drain phase %q", cfg.Pool, st.Phase)
	}
}

// failAndRestore scales the pool back to want (if >0) before returning PhaseFailed.
// The controller does NOT call Abort/Terminate on a Failed step, so a drain that
// fails while the pool is scaled to 0 must un-strand it here or warm capacity is
// lost. Patching to want is idempotent -- in "rewarming" the pool is already at want
// and this is a no-op; a best-effort restore failure is logged, not masked.
func (p *rpcPlugin) failAndRestore(pools dynamic.ResourceInterface, pool string, want int64, format string, a ...any) (types.RpcStepResult, types.RpcError) {
	if want > 0 {
		if err := patchReplicas(context.Background(), pools, pool, want); err != nil {
			p.logCtx.Warnf("failAndRestore: could not restore %s to replicas=%d: %v", pool, want, err)
		} else {
			p.logCtx.Infof("failAndRestore: restored %s to replicas=%d before failing", pool, want)
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
func (p *rpcPlugin) restoreIfDraining(ctx *types.RpcStepContext, op string) (types.RpcStepResult, types.RpcError) {
	if ctx == nil || len(ctx.Status) == 0 {
		return successf("%s: no drain state to unwind", op)
	}
	var st drainState
	if err := json.Unmarshal(ctx.Status, &st); err != nil {
		return successf("%s: no drain state to unwind", op)
	}
	if st.Phase != "draining" || st.Want <= 0 {
		return successf("%s: no unwind needed (phase=%s)", op, st.Phase)
	}
	var cfg drainConfig
	if err := json.Unmarshal(ctx.Config, &cfg); err != nil || cfg.Namespace == "" || cfg.Pool == "" || p.client == nil {
		return successf("%s: cannot unwind (no pool reference)", op)
	}
	pools := p.client.Resource(gvrWarmPool).Namespace(cfg.Namespace)
	if err := patchReplicas(context.Background(), pools, cfg.Pool, st.Want); err != nil {
		return types.RpcStepResult{}, types.RpcError{ErrorString: fmt.Sprintf("%s: restore replicas=%d on %s: %v", op, st.Want, cfg.Pool, err)}
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

// distinctTemplateHashes returns the unique non-empty template-hash values across
// pool sandboxes.
func distinctTemplateHashes(c context.Context, r dynamic.ResourceInterface, selector string) ([]string, error) {
	list, err := r.List(c, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, err
	}
	seen := map[string]struct{}{}
	var out []string
	for _, item := range list.Items {
		h := item.GetLabels()[labelTemplateHash]
		if h == "" {
			continue
		}
		if _, ok := seen[h]; !ok {
			seen[h] = struct{}{}
			out = append(out, h)
		}
	}
	return out, nil
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
