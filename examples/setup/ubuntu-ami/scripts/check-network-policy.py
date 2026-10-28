#!/usr/bin/env python3
"""Check that a NetworkPolicy object (JSON on stdin, as `kubectl get networkpolicy -o json`
prints it) limits the validation sandbox exactly as the README says:

  * it selects the sandbox pod (app=isolated-sandbox-pod) and has both policyTypes;
  * it allows no ingress;
  * every egress rule allows only UDP and TCP port 53, and only to pods labelled
    k8s-app=kube-dns in the namespace kubernetes.io/metadata.name=kube-system, with both
    selectors in the same `to` peer (so a pod must match both);
  * no egress rule has an empty `to` (all destinations), an ipBlock, a namespace-only or
    pod-only peer, or a port other than 53.

test.sh runs it against the live object before it relies on the policy; the clusterless test
runs it against good and broken objects. Exit 0 when it holds, 1 with one FAIL line per problem.
"""
import json
import sys

WANT_NS = {"kubernetes.io/metadata.name": "kube-system"}
WANT_POD = {"k8s-app": "kube-dns"}


def problems(np):
    bad = []
    spec = np.get("spec") or {}
    if (spec.get("podSelector") or {}).get("matchLabels") != {"app": "isolated-sandbox-pod"}:
        bad.append("podSelector is not app=isolated-sandbox-pod")
    if sorted(spec.get("policyTypes") or []) != ["Egress", "Ingress"]:
        bad.append(f"policyTypes is {spec.get('policyTypes')}, must be Ingress and Egress")
    if spec.get("ingress"):
        bad.append("ingress is not empty")
    egress = spec.get("egress")
    if not egress:
        bad.append("no egress rule: the sandbox would have no DNS")
    for i, rule in enumerate(egress or []):
        peers = rule.get("to")
        if not peers:
            bad.append(f"egress[{i}] has no 'to': it allows every destination")
        for j, peer in enumerate(peers or []):
            if "ipBlock" in peer:
                bad.append(f"egress[{i}].to[{j}] is an ipBlock")
            ns = peer.get("namespaceSelector")
            pod = peer.get("podSelector")
            if ns is None or pod is None:
                bad.append(f"egress[{i}].to[{j}] does not name both a namespace and a pod selector")
                continue
            if (ns.get("matchLabels") or {}) != WANT_NS or ns.get("matchExpressions"):
                bad.append(f"egress[{i}].to[{j}].namespaceSelector is {ns}, must be {WANT_NS}")
            if (pod.get("matchLabels") or {}) != WANT_POD or pod.get("matchExpressions"):
                bad.append(f"egress[{i}].to[{j}].podSelector is {pod}, must be {WANT_POD}")
        ports = rule.get("ports")
        if not ports:
            bad.append(f"egress[{i}] has no ports: it allows every port")
        for p in ports or []:
            if p.get("port") != 53 or p.get("protocol", "TCP") not in ("TCP", "UDP") or p.get("endPort"):
                bad.append(f"egress[{i}] allows {p}, only UDP and TCP port 53 are allowed")
    return bad


def main():
    try:
        np = json.load(sys.stdin)
    except ValueError as e:
        print(f"FAIL: not a JSON NetworkPolicy: {e}", file=sys.stderr)
        return 1
    bad = problems(np)
    for b in bad:
        print("FAIL: " + b, file=sys.stderr)
    print("NETWORK POLICY " + ("REFUSED" if bad else "OK: egress only to kube-system/k8s-app=kube-dns on port 53"),
          file=sys.stderr if bad else sys.stdout)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
