// Command sandbox-warmpool-stepplugin is the Argo Rollouts canary step plugin
// that deploy/rollout.yaml wires. It is a thin adapter: its Run method performs
// the SAME operations scripts/drain-pool.sh performs (patch the SandboxTemplate,
// then drain and re-warm the SandboxWarmPool at the new template hash), driven
// from a Rollout's step timeline instead of a shell.
//
// It is served over hashicorp/go-plugin using the argo-rollouts step-plugin RPC
// contract (github.com/argoproj/argo-rollouts/rollout/steps/plugin/rpc). The
// handshake below MUST match what the controller expects
// (MagicCookieKey/Value and the "RpcStepPlugin" dispense key), or the
// controller refuses to load the binary.
//
// See README.md "Register the step plugin on the controller" for how to build
// this binary and register it on an Argo Rollouts controller, and
// deploy/rollout.yaml for the step wiring it satisfies. The build runs in a
// container off golang:1.26, so the sample needs no Go toolchain on your
// machine (see Dockerfile).
package main

import (
	goPlugin "github.com/hashicorp/go-plugin"
	log "github.com/sirupsen/logrus"

	rolloutsPlugin "github.com/argoproj/argo-rollouts/rollout/steps/plugin/rpc"
)

// handshakeConfig matches the argo-rollouts step-plugin handshake. These values
// are fixed by the controller side (see the argo-rollouts step-plugin sample);
// a mismatch makes the controller reject the plugin at load time.
var handshakeConfig = goPlugin.HandshakeConfig{
	ProtocolVersion:  1,
	MagicCookieKey:   "ARGO_ROLLOUTS_RPC_PLUGIN",
	MagicCookieValue: "step",
}

func main() {
	log.SetFormatter(&log.TextFormatter{FullTimestamp: true})
	log.SetLevel(log.InfoLevel)
	logCtx := log.WithFields(log.Fields{"plugin": "sandbox-warmpool"})

	// The controller dispenses the plugin under the "RpcStepPlugin" key. A single
	// binary serves BOTH step names deploy/rollout.yaml uses (sandbox-template-patch and
	// sandbox-warmpool-drain); Run dispatches on RpcStepContext.PluginName, so the
	// controller ConfigMap registers both names against this one location.
	pluginMap := map[string]goPlugin.Plugin{
		"RpcStepPlugin": &rolloutsPlugin.RpcStepPlugin{Impl: New(logCtx)},
	}

	goPlugin.Serve(&goPlugin.ServeConfig{
		HandshakeConfig: handshakeConfig,
		Plugins:         pluginMap,
	})
}
