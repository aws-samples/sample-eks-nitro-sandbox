#!/usr/bin/env bash
# Print the cluster's DNS address as a one-address CIDR, for an egress policy's DNS rule
# (port 53), using kubectl only. Source it:
#
#   . scripts/coredns-cidr-from-service.sh
#   coredns_cidr_from_service 10.100.0.1                  # prints 10.100.0.10/32
#   cluster_coredns_cidr_from_service kubectl             # reads the kubernetes Service
#
# On EKS Auto Mode the node answers DNS on one fixed address taken from the cluster's
# service CIDR, and there is no kube-dns Service to look up. The Amazon EKS User Guide
# gives the rule in "Determining the CoreDNS IP address":
# https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html#_determining_the_coredns_ip_address
#
# This variant is for samples that run kubectl only, with no cluster name or Region to call
# aws eks describe-cluster with. The first address of the service CIDR belongs to the
# "kubernetes" Service in the default namespace, so that Service's clusterIP gives the CIDR:
#
#   IPv4: 10.100.0.1            -> 10.100.0.10/32  (last octet .1 becomes .10)
#   IPv6: fd12:3456:789a::1     -> fd12:3456:789a::a/128  (trailing ::1 becomes ::a)
#
# It stops with an error on anything else. ApplicationNetworkPolicy and NetworkPolicy do
# not check cidr: a malformed rule would match nothing and leave the pods without DNS
# (#104, #226). This file is the same in every sample that uses it.

# coredns_cidr_from_service CLUSTER_IP: print the DNS address, or return 1.
coredns_cidr_from_service() {
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])'
  local v4_re="^(${octet}\\.){3}1\$"
  local v6_re='^[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6}::1$'
  local ip="${1:-}"
  if [[ "$ip" =~ $v4_re ]]; then
    printf '%s10/32\n' "${ip%1}"
    return 0
  elif [[ "$ip" =~ $v6_re ]]; then
    printf '%sa/128\n' "${ip%1}"
    return 0
  fi
  printf 'unexpected clusterIP for svc/kubernetes: "%s" (expected an address ending in .1 or ::1)\n' \
    "$ip" >&2
  return 1
}

# cluster_coredns_cidr_from_service KUBECTL...: run "KUBECTL... get svc kubernetes" and print
# the DNS address. Pass the kubectl command with any --context, for example: kubectl, or
# kubectl --context my-cluster.
cluster_coredns_cidr_from_service() {
  local ip
  ip="$("$@" get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')" \
    || { printf 'could not read svc/kubernetes in the default namespace\n' >&2; return 1; }
  coredns_cidr_from_service "$ip"
}
