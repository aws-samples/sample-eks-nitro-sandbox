#!/usr/bin/env bash
# Print the cluster's DNS address as a one-address CIDR, for an egress policy's DNS rule
# (port 53). Run it or source it:
#
#   scripts/coredns-cidr.sh <cluster> <region>       # prints e.g. 10.100.0.10/32
#   . scripts/coredns-cidr.sh; coredns_cidr ipv4 10.100.0.0/16 ""
#
# On EKS Auto Mode the node answers DNS on one fixed address taken from the cluster's
# service CIDR, and there is no kube-dns Service to look up. The Amazon EKS User Guide
# gives the rule in "Determining the CoreDNS IP address":
# https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html#_determining_the_coredns_ip_address
#
#   IPv4: the .10 address of serviceIpv4Cidr   10.100.0.0/16         -> 10.100.0.10/32
#   IPv6: the network address of serviceIpv6Cidr with "a" appended
#                                               fd12:3456:789a::/108  -> fd12:3456:789a::a/128
#
# This file is the same in every sample that uses it. It stops with an error on anything
# else, because ApplicationNetworkPolicy does not check cidr: a malformed rule would match
# nothing and leave the pods without DNS (#104, #226).

# coredns_cidr FAMILY IPV4_CIDR IPV6_CIDR: FAMILY is ipv4 or ipv6, as describe-cluster
# reports it. Accepts an IPv4 /12 to /24 ending in .0 (the range EKS allows), or an IPv6
# /64 to /112 written with a trailing "::" (EKS gives a /108).
coredns_cidr() {
  local v4_re='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\.){3}0/(1[2-9]|2[0-4])$'
  local v6_re='^[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6}::/(6[4-9]|[7-9][0-9]|10[0-9]|11[0-2])$'
  case "$1" in
    ipv4) [[ "$2" =~ $v4_re ]] && printf '%s.10/32\n' "${2%.0/*}" && return 0 ;;
    ipv6) [[ "$3" =~ $v6_re ]] && printf '%sa/128\n' "${3%/*}" && return 0 ;;
  esac
  printf 'no usable service CIDR (ipFamily=%s serviceIpv4Cidr=%s serviceIpv6Cidr=%s)\n' \
    "${1:-none}" "${2:-none}" "${3:-none}" >&2
  return 1
}

# cluster_coredns_cidr CLUSTER REGION: read the cluster's network config and print its DNS
# address. When ipFamily is missing, an IPv4 service CIDR means IPv4, else IPv6.
cluster_coredns_cidr() {
  local net family v4 v6
  net="$(aws eks describe-cluster --name "$1" --region "$2" --output text \
    --query 'cluster.kubernetesNetworkConfig.[ipFamily,serviceIpv4Cidr,serviceIpv6Cidr]')" \
    || { printf 'could not describe cluster %s in %s\n' "$1" "$2" >&2; return 1; }
  read -r family v4 v6 <<<"$net"
  [[ "$v4" == None ]] && v4=""
  [[ "$v6" == None ]] && v6=""
  if [[ "$family" != ipv4 && "$family" != ipv6 ]]; then
    if [[ -n "$v4" ]]; then family=ipv4; else family=ipv6; fi
  fi
  coredns_cidr "$family" "$v4" "$v6"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  [[ $# -eq 2 && -n "$1" && -n "$2" ]] || { echo "usage: $0 <cluster> <region>" >&2; exit 2; }
  cluster_coredns_cidr "$1" "$2"
fi
