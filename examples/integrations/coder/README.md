# Give every developer a Coder workspace in its own Nitro sandbox

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
blueprint first so you have a cluster with the runtime classes. This blueprint builds on
[VS Code in the browser](../../agent-sandbox/ide/README.md) (code-server in a sandbox) and
[Coding agents for developers](../../ai-agents/coding-agents-for-developers/README.md)
(Claude Code on Amazon Bedrock through EKS Pod Identity). The commands below use files from
this repository, so clone it if you have not already, and run them from this blueprint's
folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/integrations/coder
```

For this blueprint you also need, on your own machine:

- The [Coder CLI](https://coder.com/docs/install/cli), version 2.38.10, the same version as
  the server. Coder's install script takes an exact version:
  `curl -fsSL https://coder.com/install.sh | sh -s -- --version 2.38.10`. On Windows, use the
  `coder_2.38.10_windows_amd64.zip` from the
  [v2.38.10 release](https://github.com/coder/coder/releases/tag/v2.38.10).
- [Helm](https://helm.sh/docs/intro/install/) 3 or 4, `jq`, `openssl` and `curl`. The scripts
  also use the AWS CLI and `kubectl` from the home page. You do not need Terraform: Coder runs
  it inside the cluster.
- A browser, to sign in through Keycloak.
- Access to the Anthropic Claude model in
  [Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) in
  your Region. Workspaces use `us.anthropic.claude-sonnet-5-5`; `BEDROCK_MODEL_ID` in `.env`
  changes it.

The cluster needs three things beyond Getting started, and `setup.sh` checks each one and
stops with the fix when it is missing:

- Private subnets tagged `kubernetes.io/role/internal-elb=1`, so EKS Auto Mode can place an
  internal load balancer (Amazon EKS User Guide,
  [*Tag subnets for EKS Auto Mode*](https://docs.aws.amazon.com/eks/latest/userguide/tag-subnets-auto.html)).
  The tag is on the VPC's subnets, which other workloads share, so adding it is your step,
  not the script's.
- An internet gateway on the VPC, which
  [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
  require even though they do not route through it.
- A Region where CloudFront VPC origins are available.

Beyond the cluster, a run costs Bedrock tokens for the Claude Code prompts, an internal
Application Load Balancer (hourly plus LCU charges), CloudFront requests and data transfer,
and one EBS volume per workspace plus PostgreSQL's volume while they exist. Coder Community
Edition needs no license.

## Overview

A platform team that hands every developer a cloud workspace runs every developer's code,
and every agent's tool call, on shared infrastructure. [Coder](https://coder.com/docs) is a
self-hosted platform for exactly that: an admin publishes a Terraform template, and Coder
creates, stops, starts and deletes one workspace per developer from it. This blueprint runs
Coder Community Edition on Amazon EKS and has its template make each workspace a pod with
`runtimeClassName: isolated-sandbox`, so a developer's terminal, their browser IDE and
Claude Code all run in a Nitro sandbox of their own.

The Coder control plane (`coderd`), the Keycloak identity provider and the PostgreSQL
database they share are ordinary pods in the namespace `coder`. They run code the platform
team chose. The workspaces, which run code any developer or agent chose, live in the
namespace `coder-workspaces`, each in its own sandbox.

- **Each workspace is a Nitro sandbox.** Coder's template creates a Deployment with one pod
  per running workspace, and that pod sets `runtimeClassName: isolated-sandbox`. The page
  shows the pod's own kernel build, boot and virtio disks, each next to what an ordinary pod
  on the same node shows.
- **Coder's Kubernetes access covers only the workspaces.** Coder's built-in provisioner runs
  inside `coderd` and creates workspaces with a Role in `coder-workspaces` that covers
  Deployments and PersistentVolumeClaims there. The chart's own Role is off, and Step 4 shows
  what that leaves.
- **Everyone signs in through Keycloak, over HTTPS.** Admins and developers open one
  `https://` address on Amazon CloudFront and sign in as Keycloak users that setup generates
  with random passwords. Coder's own password sign-in is off.
- **Claude Code uses Bedrock with no key.** Each workspace pod's ServiceAccount has an EKS
  Pod Identity role that may invoke the configured model and nothing else, and the page
  shows its policy document.
- **Stop frees the sandbox, the home volume stays.** Stopping a workspace deletes its pod and
  keeps its EBS claim; starting it boots a new pod in a new sandbox on the same files.
- **One template, many developers.** Two developers start a workspace from the same template,
  and each one runs in its own sandbox.

Developers' browsers reach Coder and Keycloak through CloudFront, whose VPC origin is an
internal Application Load Balancer (ALB) that EKS Auto Mode creates from the blueprint's
Ingress. The workspaces connect to what the template has them use: Amazon Bedrock, the
`coderd` Service inside the cluster, and the sites the Coder registry modules download
code-server and Claude Code from.

*Figure 1: Coder on Amazon EKS behind Amazon CloudFront. A developer reaches Coder and Keycloak only through CloudFront and an internal load balancer, and every workspace Coder creates runs in its own Nitro sandbox.*

![An architecture figure read from left to right. A browser on the internet sends HTTPS requests to Amazon CloudFront, which answers on a cloudfront.net address inside the AWS Cloud frame. CloudFront connects over HTTP on port 80 to a VPC origin, and the VPC origin connects to an internal Application Load Balancer that admits only CloudFront. The VPC origin and the load balancer sit in a dashed frame labelled VPC with private subnets, which also holds the Amazon EKS cluster. The load balancer sends the path / to Coder and the path /auth to Keycloak. Coder, Keycloak and PostgreSQL are ordinary pods in the namespace coder. PostgreSQL has no connection from the load balancer. Coder has an arrow labelled creates workspaces to the namespace coder-workspaces, which holds two workspaces. Each workspace is a Nitro sandbox pod with runtimeClassName isolated-sandbox, runs Claude Code and code-server, and has its own Amazon EBS home volume attached below it. Each workspace pod has an arrow labelled EKS Pod Identity to Amazon Bedrock, which sits outside the VPC on the right of the AWS Cloud frame.](images/coder-overview.png)

## The HTTPS endpoint, and who can reach what

This blueprint gives Coder a public HTTPS address, because Coder needs one address that the
browser and the cluster can both reach. Coder builds its dashboard links, its sign-in
redirect and, by default, the address its workspace agents connect to from a single setting,
the access URL (`CODER_ACCESS_URL`). Sign-in has the same need: the browser is sent to the
Keycloak issuer URL to sign in, and `coderd` reads the same URL when it starts and checks
every sign-in against it. A `kubectl port-forward` address exists only on the machine that
runs it, so it can be neither. The distribution's default `dXXXX.cloudfront.net` name and
certificate give the browser, `coderd` and the workspaces one HTTPS address, with no domain
of your own:

- `https://<DOMAIN>/` is Coder.
- `https://<DOMAIN>/auth/` is Keycloak, with the realm `coder` and the issuer
  `https://<DOMAIN>/auth/realms/coder`.

<!-- excerpt: deploy/coder-values.yaml -->
```yaml
    # The one URL the browser and the workspace agents both use. Setting it
    # here also stops the chart from adding its in-cluster default.
    - name: CODER_ACCESS_URL
      value: "https://<DOMAIN>"
```

CloudFront redirects plain HTTP to HTTPS, caches nothing and passes the viewer's headers,
cookies and query strings on. It reaches the ALB over HTTP on port 80 through a
[VPC origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html).
The ALB is internal, in the cluster's private subnets:

<!-- excerpt: deploy/ingress.yaml -->
```yaml
spec:
  # Private IP addresses only. CloudFront reaches it through the VPC origin.
  scheme: internal
  ipAddressType: ipv4
```

Setup names the subnets too: the cluster's private subnets, the ones with no route to an
internet gateway. Once Auto Mode has created the ALB, setup checks that it is internal, sits in
exactly those subnets and has no public IP address on any of its network interfaces. If any of
that is not so, setup deletes the Ingress, so Auto Mode removes the load balancer, and stops.
You can read the same three things yourself:

```bash
lb_arn="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-coder-coder')].LoadBalancerArn" --output text)"
aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$lb_arn" \
  --query 'LoadBalancers[0].{Scheme:Scheme,Subnets:AvailabilityZones[].SubnetId}'
aws ec2 describe-route-tables --region "$AWS_REGION" \
  --filters "Name=association.subnet-id,Values=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --load-balancer-arns "$lb_arn" --query 'join(`,`, LoadBalancers[0].AvailabilityZones[].SubnetId)' --output text)" \
  --query 'RouteTables[].{Subnets:Associations[].SubnetId,DefaultRoute:Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId][]}'
aws ec2 describe-network-interfaces --region "$AWS_REGION" \
  --filters "Name=description,Values=ELB ${lb_arn#*:loadbalancer/}" \
  --query 'NetworkInterfaces[].{PrivateIp:PrivateIpAddress,PublicIp:Association.PublicIp}'
```

```text
TODO: output from the fresh run
```

The scheme is `internal`, each subnet's default route goes to a NAT gateway rather than an
internet gateway, and no network interface has a public IP address.

The ALB's security group, `coder-alb-origin`, is the blueprint's own, and it has one inbound
rule: TCP 80 from `CloudFront-VPCOrigins-Service-SG`, the group CloudFront creates and manages
for its VPC origins in your VPC. So the distribution is the only way to the ALB:

<!-- excerpt: deploy/ingress.yaml -->
```yaml
    # The blueprint's own security group instead of one Auto Mode would open to
    # 0.0.0.0/0. It has no inbound rule until setup adds the single rule that admits
    # CloudFront's VPC origin security group.
    alb.ingress.kubernetes.io/security-groups: <SECURITY_GROUP_ID>
```

Once setup has run (Step 1, which also sets the variables these commands use), read the rule
and the group it admits:

```bash
aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters Name=group-name,Values=coder-alb-origin Name=tag:ManagedBy,Values=coder \
  --query 'SecurityGroups[].{GroupId:GroupId,Inbound:IpPermissions}'
aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters Name=group-name,Values=CloudFront-VPCOrigins-Service-SG \
  --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId}'
```

```text
TODO: output from the fresh run
```

The ALB routes two paths and nothing else. PostgreSQL has no route, and neither has
Keycloak's management port, 9000, where its health checks live:

<!-- excerpt: deploy/ingress.yaml -->
```yaml
spec:
  ingressClassName: coder-alb
  rules:
    - http:
        paths:
          # Keycloak serves everything under /auth (KC_HTTP_RELATIVE_PATH=/auth). Its
          # management port, 9000, is not routed.
          - path: /auth
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080
          # coder-route: begin. Everything else is Coder. Added by setup's second apply.
          - path: /
            pathType: Prefix
            backend:
              service:
                name: coder
                port:
                  number: 80
          # coder-route: end
```

Who can reach what:

| Who | What they reach | What it takes |
|---|---|---|
| Anyone on the internet | Coder's sign-in page, whose only option is **Sign in with Keycloak**; Keycloak's sign-in pages for the realm `coder`; the sign-in page of Keycloak's admin console; and the endpoints sign-in itself needs before anyone is signed in, such as Coder's `/api/v2/users/authmethods` and Keycloak's discovery document | Nothing: these are public |
| A Keycloak user in the realm `coder` (`admin`, `dev1`, `dev2`) | The Coder dashboard, their own workspaces, the web terminal and code-server. `admin` is a Coder owner and also publishes templates and manages users | A Keycloak sign-in with the random password setup generated |
| Keycloak's own admin, in the realm `master` | The Keycloak admin console at `https://<DOMAIN>/auth/admin/` | Keycloak's admin password, random, in `tmp/coder/keycloak-admin-password` with mode 600 |
| No one from outside the cluster | PostgreSQL, Keycloak's management port, the `coder` and `keycloak` Services, and the ALB itself | Not routed, or admitted only from CloudFront's VPC origin group |

**The order setup opens it in.** Two Coder behaviours set the order. While Coder has no
user, anyone who reaches it can create the first owner, and the first account to sign in
through Keycloak becomes an owner too. And `coderd` stops at start-up if it cannot read
Keycloak's discovery document, which is only reachable through the distribution. So
[`scripts/setup.sh`](scripts/setup.sh) exposes Keycloak first, alone, and Coder last:

1. It creates the ALB with its security group closed and only the `/auth` route, then the VPC
   origin and the distribution, so the `dXXXX.cloudfront.net` name is known before anything
   is configured with it.
2. It starts Keycloak with the realm `coder` holding Coder's OIDC client and no users, with
   self-registration off and a random admin password, and only then opens the security
   group. At this point the only thing on the internet is a sign-in page nobody can sign in
   to, apart from Keycloak's own admin.

   <!-- excerpt: deploy/realm.json -->
   ```json
     "sslRequired": "all",
     "registrationAllowed": false,
   ```

3. It installs Coder with Keycloak sign-in on. Coder has no route yet. Setup creates the
   owner from inside the cluster: a short-lived bootstrap user, then `admin` as a Keycloak
   sign-in owner, then it deletes the bootstrap user. With a user in place, the first-user
   page is closed.
4. It turns Coder's password sign-in off with a `helm upgrade`, so Keycloak is the only way
   to sign in, admins included.

   <!-- excerpt: deploy/coder-values.yaml -->
   ```yaml
       # "false" while setup creates the owner, then "true" for good. With it on,
       # Coder refuses every password sign-in and refuses to create password users.
       - name: CODER_DISABLE_PASSWORD_AUTH
         value: "<DISABLE_PASSWORD_AUTH>"
   ```

5. It adds the `/` route to Coder, and shows anonymous requests refused (Step 2).
6. Only then does it create the Keycloak users, each with a random password.

## Versions

This folder was built against these releases:

| Component | Version |
|---|---|
| Coder Helm chart, server and CLI ([coder/coder](https://github.com/coder/coder/releases/tag/v2.38.10)), stable channel, Community Edition | 2.38.10, chart `oci://ghcr.io/coder/chart/coder` |
| Coder Terraform provider ([coder/terraform-provider-coder](https://github.com/coder/terraform-provider-coder/releases/tag/v2.20.0)) | 2.20.0 |
| Kubernetes Terraform provider ([hashicorp/terraform-provider-kubernetes](https://github.com/hashicorp/terraform-provider-kubernetes/releases/tag/v3.5.0)) | 3.5.0 |
| code-server module ([registry.coder.com/coder/code-server](https://registry.coder.com/modules/coder/code-server)) | 1.6.0 |
| code-server, installed by the module ([coder/code-server](https://github.com/coder/code-server/releases/tag/v4.145.2)) | 4.145.2 |
| Claude Code module ([registry.coder.com/coder/claude-code](https://registry.coder.com/modules/coder/claude-code)) | 5.5.2 |
| Workspace image ([codercom/enterprise-base](https://hub.docker.com/r/codercom/enterprise-base/tags?name=ubuntu-20261112)) | `ubuntu-20261112` |
| Keycloak ([keycloak/keycloak](https://github.com/keycloak/keycloak/releases/tag/26.8.2)) | 26.8.2, as `quay.io/keycloak/keycloak:26.8.2` |
| PostgreSQL ([official image](https://hub.docker.com/_/postgres)) | 18.7, as `postgres:18.7` |

Coder's [release channels](https://coder.com/docs/reference/releases) page calls the stable
channel the safest installation path, which is why the blueprint pins 2.38.10 rather than the
newer mainline release.

## Files

| File | What it is |
|---|---|
| [`deploy/postgres.yaml`](deploy/postgres.yaml) | PostgreSQL: one pod, one EBS volume, two databases (`coder` and `keycloak`), each with its own role and generated password |
| [`deploy/keycloak.yaml`](deploy/keycloak.yaml) | Keycloak in production mode under `/auth`, and its `ClusterIP` Service |
| [`deploy/realm.json`](deploy/realm.json) | The realm `coder`: Coder's confidential OIDC client, no users, self-registration off |
| [`deploy/coder-values.yaml`](deploy/coder-values.yaml) | Helm values for Coder: `ClusterIP` Service, access URL, Keycloak sign-in, password sign-in switch |
| [`deploy/ingress.yaml`](deploy/ingress.yaml) | `IngressClassParams` and `IngressClass` `coder-alb` (internal ALB), and the Ingress with the `/auth` and `/` routes |
| [`deploy/workspace-rbac.yaml`](deploy/workspace-rbac.yaml) | The workspaces' ServiceAccount, and the Role and RoleBinding that are Coder's only Kubernetes permission |
| [`deploy/storage-class.yaml`](deploy/storage-class.yaml) | The blueprint's own EBS `StorageClass`, created only when the cluster has no default class that fits |
| [`templates/claude-code-nitro/main.tf`](templates/claude-code-nitro/main.tf) | The Coder template: each workspace is an `isolated-sandbox` pod with Claude Code, code-server and an EBS home |
| [`templates/claude-code-nitro/.terraform.lock.hcl`](templates/claude-code-nitro/.terraform.lock.hcl) | The template's provider lock file, so Coder installs the same provider builds each time |
| [`scripts/common.sh`](scripts/common.sh) | Names, defaults and helpers the two scripts share |
| [`scripts/setup.sh`](scripts/setup.sh) | Checks, installs, the ALB, CloudFront, the owner, the anonymous checks, the Keycloak users and the template variables |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Removes everything the blueprint created, and only that |
| [`.env.example`](.env.example) | The local values the blueprint reads, with their defaults |

**Step 1: Configure `.env` and run setup.** Every value has a default, so `.env` is optional.
Set `KUBE_CONTEXT` to the context of the cluster you ran Getting started on, so a run never
depends on the machine's current context; setup also checks that the context's API server is
the endpoint `aws eks describe-cluster` reports for `CLUSTER_NAME`, and stops if it is not.

| Name | Default | What it sets |
|---|---|---|
| `NAMESPACE` | `coder` | The namespace for `coderd`, Keycloak and PostgreSQL |
| `WORKSPACE_NAMESPACE` | `coder-workspaces` | The namespace Coder creates workspaces in |
| `KUBE_CONTEXT` | the current context | The cluster the scripts talk to |
| `CLUSTER_NAME`, `AWS_REGION` | `sandbox-demo`, `us-west-2` | The EKS cluster and its Region |
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-sonnet-5-5` | The inference profile Claude Code uses, and the only one the Pod Identity role may invoke |
| `DEVELOPER_COUNT` | `2` | How many developer users (`dev1` to `devN`) setup creates, besides `admin` |
| `LOCAL_DIR` | `tmp/coder` under the repository root | Where setup writes passwords, generated files and its state, all mode 600; the repository's `tmp/` is git-ignored |

Setup installs Coder with these values. Here is the part of
[`deploy/coder-values.yaml`](deploy/coder-values.yaml) that points Coder at Keycloak:

<!-- excerpt: deploy/coder-values.yaml -->
```yaml
    # Sign in with Keycloak. coderd reads the issuer's discovery document at
    # startup and exits if it cannot, so the Keycloak route on the
    # distribution must answer before this release starts.
    - name: CODER_OIDC_ISSUER_URL
      value: "https://<DOMAIN>/auth/realms/coder"
    - name: CODER_OIDC_CLIENT_ID
      value: "coder"
    - name: CODER_OIDC_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: coder-oidc
          key: client-secret
```

Every password and the OIDC client secret come from `openssl`, are written to files under
`LOCAL_DIR` with mode 600, and reach the cluster as Kubernetes Secrets created from those
files, so none of them is on a command line.

```bash
cp .env.example .env    # optional: set KUBE_CONTEXT, and anything else you want to change
./scripts/setup.sh
```

```text
TODO: output from the fresh run
```

Setup prints thirteen step headers in the order of the previous section, then the Coder and
Keycloak addresses, where it wrote the passwords, and the next commands. The rest of this
page uses the distribution's name, which setup keeps in its state file, and the names from
`.env`. Set them in each shell you use, with your own values if you changed them:

```bash
export DOMAIN=$(sed -n 's/^DOMAIN=//p' ../../../tmp/coder/state.env)
export NAMESPACE=coder WORKSPACE_NAMESPACE=coder-workspaces CLUSTER_NAME=sandbox-demo AWS_REGION=us-west-2
echo "https://$DOMAIN"
```

```text
TODO: output from the fresh run
```

**Step 2: Check the endpoint before any Keycloak user exists.** Setup's step 11 is this check.
It sends anonymous requests through the distribution after Coder is routed and before step 12
creates a single Keycloak user, and it stops if any of them is not refused. Here is that part
of the setup output:

```text
TODO: output from the fresh run
```

Read it line by line. Plain HTTP is redirected to HTTPS. Coder's API answers an anonymous
request with 401. A request to create the first user is refused with 409, because the owner
already exists, so the first-user setup page is closed. The sign-in methods are Keycloak
only, with password sign-in off. Keycloak's admin console sends an anonymous visitor to
Keycloak's sign-in.

The same checks, from your own machine, at any time:

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "http://$DOMAIN/"
curl -sS -w '\n%{http_code}\n' "https://$DOMAIN/api/v2/users/me"
curl -sS -w '\n%{http_code}\n' "https://$DOMAIN/api/v2/users/first"
curl -sS "https://$DOMAIN/api/v2/users/authmethods" | jq -c '{password: .password.enabled, oidc: .oidc.enabled}'
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$DOMAIN/auth/admin/"
curl -sS -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/"
```

```text
TODO: output from the fresh run
```

`GET /api/v2/users/first` answers that the first user has already been created, and `/`
serves Coder's sign-in page, whose one button sends you to Keycloak.

**Step 3: Sign in as the admin and publish the template.** `tmp/coder/users.txt` holds one
line per Keycloak user: user name, email and password. Keep each person's Coder CLI session in
its own folder, so you can be the admin and two developers from one machine. `coder login`
opens `/cli-auth` in your browser (or prints the address); sign in with Keycloak as `admin`,
and paste the token the page shows. The token prompt hides what you paste, so the token is not
on a command line either.

```bash
export CODER_CONFIG_DIR="$PWD/../../../tmp/coder/cli-admin"
coder login "https://$DOMAIN"
```

```text
TODO: output from the fresh run
```

The template's variables are in `tmp/coder/template-variables.yaml`, which setup wrote:
the workspace namespace and ServiceAccount, the StorageClass it chose, the model, the Region,
and the in-cluster address of Coder. That last one keeps workspace agents off CloudFront: the
template's Coder provider gives the agent the in-cluster Service as the address to download
its binary from and connect to:

<!-- excerpt: templates/claude-code-nitro/main.tf -->
```hcl
# The url argument sets the address that the workspace agent uses to download its binary
# and to connect to Coder. When it is empty, the provider keeps the access URL that Coder
# passes to the provisioner. Pointing it at the in-cluster Service keeps agent traffic
# inside the cluster, so it does not go out through CloudFront and back.
provider "coder" {
  url = var.coder_internal_url != "" ? var.coder_internal_url : null
}
```

```bash
cat ../../../tmp/coder/template-variables.yaml
coder templates push claude-code-nitro --directory templates/claude-code-nitro \
  --variables-file ../../../tmp/coder/template-variables.yaml --yes
coder users list -o json | jq -r '.[] | [.username, .login_type, ([.roles[].name] | join(","))] | @tsv'
```

```text
TODO: output from the fresh run
```

The push runs `terraform` inside `coderd` and publishes the template. `admin` is a Keycloak
(`oidc`) user with the `owner` role, and is the only user so far.

**Step 4: Sign in as a developer and create a workspace.** In a second shell, from this
folder, be `dev1`: sign in with Keycloak as `dev1` and paste the token. Coder creates the
account at the first sign-in, as a member. Then create a workspace from the template. The
template asks one question, the size of the home volume, and `--use-parameter-defaults` takes
its default of 10 GiB.

```bash
export CODER_CONFIG_DIR="$PWD/../../../tmp/coder/cli-dev1"
coder login "https://$DOMAIN"
coder create claude --template claude-code-nitro --use-parameter-defaults --yes
coder list
```

```text
TODO: output from the fresh run
```

The workspace is a Deployment that Coder's provisioner creates in `coder-workspaces`. Here is
the part of the template's pod spec that makes it a sandbox and gives it its AWS identity:

<!-- excerpt: templates/claude-code-nitro/main.tf -->
```hcl
        runtime_class_name = "isolated-sandbox"

        # EKS Pod Identity maps this ServiceAccount to an IAM role that can call Bedrock.
        # The setup script creates the ServiceAccount and the association.
        service_account_name = var.service_account
```

The provisioner can create that Deployment because of the Role in
[`deploy/workspace-rbac.yaml`](deploy/workspace-rbac.yaml), which is all Coder may do in the
cluster. The Helm values turn the chart's own Role off:

<!-- excerpt: deploy/workspace-rbac.yaml -->
```yaml
rules:
  # The workspace itself: a Deployment with one replica, created on start and
  # destroyed on stop and delete. The Terraform Kubernetes provider reads,
  # creates, updates and deletes it by name.
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "create", "update", "patch", "delete"]
  # The home volume: one ReadWriteOncePod claim per workspace. Created with the
  # workspace, kept across stop and start, deleted with the workspace.
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "create", "update", "patch", "delete"]
```

```bash
kubectl -n "$WORKSPACE_NAMESPACE" get deploy,pod,pvc -l com.coder.user.username=dev1 -o wide
kubectl auth can-i --list -n "$WORKSPACE_NAMESPACE" --as "system:serviceaccount:$NAMESPACE:coder"
kubectl auth can-i create pods -n "$NAMESPACE" --as "system:serviceaccount:$NAMESPACE:coder"
```

```text
TODO: output from the fresh run
```

One Deployment, one pod and one `Bound` claim belong to `dev1`. Coder's ServiceAccount may
manage Deployments and claims in the workspace namespace and may not create a pod in its own.

Open the workspace in the browser too: `https://<DOMAIN>/@dev1/claude` shows the workspace,
its **Guest kernel** value from the template's metadata, the web terminal and a
**code-server** button.

**Step 5: Look inside the sandbox.** Read the workspace pod's runtime class, kernel, boot,
disks and memory, then read the same from an ordinary pod that runs on the same node for the
comparison and is deleted by name afterwards. `/proc/sys/kernel/random/boot_id` is a UUID the
kernel generates once per boot
([kernel documentation](https://docs.kernel.org/admin-guide/sysctl/kernel.html)), so it names
the kernel a pod is running on.

```bash
WS_POD=$(kubectl -n "$WORKSPACE_NAMESPACE" get pod -l com.coder.user.username=dev1 -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl -n "$WORKSPACE_NAMESPACE" get pod "$WS_POD" -o jsonpath='{.spec.nodeName}')
kubectl -n "$NAMESPACE" run ordinary --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$NODE\"}}" --command -- sleep 600
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/ordinary --timeout=3m

CHECK='uname -rv; cut -d" " -f1 /proc/uptime; cat /proc/sys/kernel/random/boot_id;
       ls /sys/block | tr "\n" " "; echo; cat /sys/class/dmi/id/product_name; grep MemTotal /proc/meminfo'
echo "--- workspace pod $WS_POD ---"
kubectl -n "$WORKSPACE_NAMESPACE" get pod "$WS_POD" -o jsonpath='runtimeClassName={.spec.runtimeClassName} node={.spec.nodeName} started={.status.startTime}{"\n"}'
kubectl -n "$WORKSPACE_NAMESPACE" exec "$WS_POD" -- sh -c "$CHECK"
kubectl -n "$WORKSPACE_NAMESPACE" exec "$WS_POD" -- df -h /home/coder
echo "--- ordinary pod ---"
kubectl -n "$NAMESPACE" get pod ordinary -o jsonpath='runtimeClassName={.spec.runtimeClassName} node={.spec.nodeName} started={.status.startTime}{"\n"}'
kubectl -n "$NAMESPACE" exec ordinary -- sh -c "$CHECK"
date -u +%Y-%m-%dT%H:%M:%SZ
kubectl -n "$NAMESPACE" delete pod ordinary
```

```text
TODO: output from the fresh run
```

The runtime class shows what was asked for; the rest shows what ran. Both pods are on the
same node:

- **Its own kernel.** `uname -rv` in the workspace shows the guest's kernel build. The
  ordinary pod shows the node's. The version string can match; the build does not.
- **Its own boot.** The workspace's uptime matches the pod's age, because its sandbox booted
  with the pod. The ordinary pod reports the node's uptime, and the two `boot_id` values differ.
- **Virtio disks.** The workspace sees `vd*` devices, and `df` shows the home directory is
  one of them. The ordinary pod sees the instance's `nvme` devices.
- **The sandbox's own product name.** The workspace reads the sandbox's product name, where
  the ordinary pod reads the EC2 instance type.

Together they show the workspace's containers run in a lightweight VM of their own, with a
kernel no other pod shares. `MemTotal` follows the workspace's 1Gi memory request (see
[Why workspaces request 1Gi of memory](#why-workspaces-request-1gi-of-memory)).

**Step 6: Claude Code answers through Bedrock, with no key.** The template turns on Claude
Code's Bedrock mode and sets the model and the Region; it holds no API key. Claude Code finds
its AWS credentials through the standard credential chain, which on this pod is EKS Pod
Identity for the ServiceAccount `coder-workspace`. Setup builds the role's policy from the
inference profile `BEDROCK_MODEL_ID` names and the foundation models
`aws bedrock get-inference-profile` says it routes to. Here is the part of
[`scripts/setup.sh`](scripts/setup.sh) that writes the two policy documents:

<!-- excerpt: scripts/setup.sh -->
```bash
jq -n '{Version:"2012-10-17",Statement:[{Sid:"EksPodIdentity",Effect:"Allow",
  Principal:{Service:"pods.eks.amazonaws.com"},Action:["sts:AssumeRole","sts:TagSession"]}]}' \
  >"$LOCAL_DIR/workspace-trust-policy.json"
# The only grant: invoke the configured inference profile and the foundation models it routes to.
jq '{Version:"2012-10-17",Statement:[{Sid:"InvokeConfiguredModel",Effect:"Allow",
  Action:["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  Resource:([.inferenceProfileArn] + [.models[].modelArn])}]}' <<<"$profile" \
  >"$LOCAL_DIR/workspace-bedrock-policy.json" || die "could not write the role policy"
```

The role and its policies, read from IAM, and the association that ties it to the
workspaces' ServiceAccount:

```bash
ROLE=coder-workspace-bedrock-$CLUSTER_NAME
aws iam get-role-policy --role-name "$ROLE" --policy-name bedrock-invoke --query PolicyDocument
aws iam list-attached-role-policies --role-name "$ROLE"
aws iam get-role --role-name "$ROLE" --query Role.AssumeRolePolicyDocument
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace "$WORKSPACE_NAMESPACE" --service-account coder-workspace
```

```text
TODO: output from the fresh run
```

The role may call `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on the
configured inference profile and the foundation models it routes to, and nothing else: it has
no attached policies, and only EKS Pod Identity may assume it. That is a limit this blueprint
enforces: code in a workspace, including anything Claude Code runs, can use the role for
those two actions on those models only.

Now, as `dev1`, look at the workspace's environment by name only, and ask Claude Code
something. The `claude` binary is in `~/.local/bin`, which the template puts on the PATH of
interactive shells; a command run with `coder ssh` names it in full.

```bash
coder ssh claude -- 'env | cut -d= -f1 | grep -E "^(AWS_|CLAUDE_CODE_|ANTHROPIC_)" | sort'
coder ssh claude -- '~/.local/bin/claude -p "In one sentence, say hello from this workspace."'
```

```text
TODO: output from the fresh run
```

The names show Bedrock mode, the model, the Region and the Pod Identity credential endpoint
and token file, and no `ANTHROPIC_API_KEY` or `AWS_SECRET_ACCESS_KEY`. Claude's answer came
from Bedrock with those credentials. You can do the same in the browser: open the workspace's
terminal and run `claude`.

**Step 7: Stop and start keep the home volume.** The home claim has no `count`, so it exists
for the life of the workspace; the Deployment's `count` follows the workspace state, so
stopping deletes it and its pod:

<!-- excerpt: templates/claude-code-nitro/main.tf -->
```hcl
# ---------------------------------------------------------------------------
# Persistent home: one ReadWriteOncePod EBS volume per workspace, so only one pod can ever
# mount it (a block device attaches to one sandbox at a time). It has no count, so it stays
# when the workspace is stopped and is removed only when the workspace is deleted.
# ---------------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim_v1" "home" {
```

<!-- excerpt: templates/claude-code-nitro/main.tf -->
```hcl
resource "kubernetes_deployment_v1" "workspace" {
  # One Deployment while the workspace is started, none while it is stopped. Stopping
  # deletes the sandbox pod, and starting boots a new one on the same home volume claim.
  count = data.coder_workspace.me.start_count
```

*Figure 2: What stop and start do to a workspace. Stop removes the pod and its sandbox and keeps the EBS claim. Start creates a new pod in a new sandbox that attaches the same claim.*

![Three boxes read from left to right, joined by two arrows. The first box, Running, holds a Nitro sandbox pod with runtimeClassName isolated-sandbox that runs the workspace with Claude Code and code-server, and an Amazon EBS home volume attached to the pod. An arrow labelled Stop leads to the second box, Stopped, which holds a dashed outline marked No pod, the pod and its sandbox are removed, and the same Amazon EBS home volume, kept, with nothing attached to it. An arrow labelled Start leads to the third box, Started again, which holds a new Nitro sandbox pod running the workspace in a new sandbox, with the same Amazon EBS home volume attached.](images/coder-workspace-lifecycle.png)

Write a file in the home directory, stop the workspace, look at what is left, start it again
and read the file:

```bash
vol() { kubectl get pv "$(kubectl -n "$WORKSPACE_NAMESPACE" get pvc -l com.coder.user.username=dev1 \
  -o jsonpath='{.items[0].spec.volumeName}')" -o jsonpath='volumeHandle={.spec.csi.volumeHandle}{"\n"}'; }
coder ssh claude -- 'echo "written before the stop" > ~/notes.txt; ls -l ~/notes.txt'
kubectl -n "$WORKSPACE_NAMESPACE" get pod -l com.coder.user.username=dev1 -o jsonpath='pod={.items[0].metadata.uid}{"\n"}'
vol
coder stop claude --yes
kubectl -n "$WORKSPACE_NAMESPACE" get deploy,pod,pvc -l com.coder.user.username=dev1
coder start claude --yes
kubectl -n "$WORKSPACE_NAMESPACE" get pod -l com.coder.user.username=dev1 -o jsonpath='pod={.items[0].metadata.uid}{"\n"}'
vol
coder ssh claude -- 'cat ~/notes.txt; cut -d" " -f1 /proc/uptime'
```

```text
TODO: output from the fresh run
```

While the workspace is stopped there is no Deployment and no pod, and the claim is still
`Bound`. After the start, the pod UID is new and its uptime is its own, so it is a new pod in
a new sandbox; the volume handle is the same EBS volume, and `notes.txt` is still there.

**Step 8: A second developer's workspace runs in its own sandbox.** In a third shell, be
`dev2` and create a workspace with the same name from the same template:

```bash
export CODER_CONFIG_DIR="$PWD/../../../tmp/coder/cli-dev2"
coder login "https://$DOMAIN"
coder create claude --template claude-code-nitro --use-parameter-defaults --yes
```

```text
TODO: output from the fresh run
```

Then compare the two workspace pods:

```bash
kubectl -n "$WORKSPACE_NAMESPACE" get pod -l app.kubernetes.io/part-of=coder \
  -o custom-columns='POD:.metadata.name,USER:.metadata.labels.com\.coder\.user\.username,RUNTIMECLASS:.spec.runtimeClassName,NODE:.spec.nodeName,STARTED:.status.startTime'
for p in $(kubectl -n "$WORKSPACE_NAMESPACE" get pod -l app.kubernetes.io/part-of=coder -o name); do
  echo "--- $p ---"
  kubectl -n "$WORKSPACE_NAMESPACE" exec "$p" -- sh -c 'cat /proc/sys/kernel/random/boot_id; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo'
done
kubectl -n "$WORKSPACE_NAMESPACE" get pvc -l app.kubernetes.io/part-of=coder
coder users list -o json | jq -r '.[] | [.username, .login_type, ([.roles[].name] | join(","))] | @tsv'
```

```text
TODO: output from the fresh run
```

Each developer has a pod with `runtimeClassName: isolated-sandbox`, and each pod reports its
own `boot_id` and its own uptime: two kernels, booted separately, even where the two pods
share a node. Each has its own home claim. The user list now shows `dev1` and `dev2` as
Keycloak (`oidc`) users with no role beyond member, and `admin` as the only owner.

## Why workspaces request 1Gi of memory

A sandbox is sized from its pod's requests when it boots, and its memory follows
`resources.requests.memory` (Amazon EKS User Guide,
[*Considerations*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-limitations.html),
"Usable memory"). With no requests at all, the sandbox gets a small default size: the
[hello sandbox](../../getting-started/hello-sandbox/README.md) pods got one vCPU and about
130 MiB of memory, which suits a pod that prints a line and sleeps. A workspace runs the Coder
agent, code-server and Claude Code at once, so the template asks for memory and sets nothing
else:

<!-- excerpt: templates/claude-code-nitro/main.tf -->
```hcl
          # The guest's memory follows this memory request. It is the only size the
          # template sets: no CPU request and no limits.
          resources {
            requests = {
              memory = "1Gi"
            }
          }
```

The template sets no CPU request and no limits: nothing in the blueprint needs them, and a
limit above the request would not make the sandbox bigger. Size the request for your own
developers' work.
The sandbox's CPU and memory are set when it boots and cannot be resized in place, so a new
request takes effect at the workspace's next start, when Coder creates a new pod. Each
sandbox reserves its full memory request on the node, so nodes fill by reservation rather
than by use ([warm pool](../../getting-started/warm-pool/README.md), "Sizing").

## Community Edition and Coder Premium

This blueprint runs Community Edition, which is free and needs no license. Each row was read
on Coder's own pages:

| Capability | Community Edition | Coder Premium | Source |
|---|---|---|---|
| OIDC sign-in with any provider (here, Keycloak) | Included | Included | [OIDC](https://coder.com/docs/admin/users/oidc-auth), [pricing](https://coder.com/pricing) |
| Turn password sign-in off (`CODER_DISABLE_PASSWORD_AUTH`) | Included | Included | [Password authentication](https://coder.com/docs/admin/users/password-auth), [server reference](https://coder.com/docs/reference/cli/server#--disable-password-auth) |
| Assign roles (Owner, User Admin, Template Admin, Auditor) by hand | Included; only an Owner changes roles | Included | [Groups and roles](https://coder.com/docs/admin/users/groups-roles) |
| Sync roles, groups and organizations from the identity provider | Not included | Included | [IdP sync](https://coder.com/docs/admin/users/idp-sync) |
| Groups | Not included | Included | [Groups and roles](https://coder.com/docs/admin/users/groups-roles) |
| More than one `coderd` replica (high availability) | Not included; run one replica | Included | [High availability](https://coder.com/docs/admin/networking/high-availability) |
| Audit logs | Not included | Included | [Audit logs](https://coder.com/docs/admin/security/audit-logs) |
| Template permissions (who may use or edit each template) | Not included | Included | [Template permissions](https://coder.com/docs/admin/templates/template-permissions) |
| Workspace quotas | Not included | Included | [Quotas](https://coder.com/docs/admin/users/quotas) |
| External provisioners | Not included; the built-in provisioners in `coderd` run the builds | Included | [External provisioners](https://coder.com/docs/install/operate/provisioners) |
| AI Gateway and Agent Firewall | Not included | Included | [AI Governance](https://coder.com/docs/ai-coder/ai-governance), [Licensing](https://coder.com/docs/install/prepare/licensing) |
| Number of users and workspaces | Unlimited | Unlimited; priced per user | [Pricing](https://coder.com/pricing), FAQ |

Two rows matter for this blueprint. With no identity provider sync on Community Edition,
Keycloak decides who can sign in, and Coder's own roles are set in Coder: that is why setup
makes `admin` an owner from inside the cluster. And without template permissions or groups,
every developer can use every template. Coder's roles still keep a member to their own
workspaces: only a Template Admin or an Owner can view everyone's, and only an Owner can open
them ([Groups and roles](https://coder.com/docs/admin/users/groups-roles)). Underneath, each
workspace runs in its own sandbox.

## Scaling past a demo

The blueprint runs one of everything. To grow it:

- **The control plane.** Community Edition runs one `coderd` replica; more replicas are
  Coder's [high availability](https://coder.com/docs/admin/networking/high-availability) mode,
  a Premium feature. Coder's [Scale Coder](https://coder.com/docs/tutorials/best-practices/scale-coder)
  guide recommends scaling `coderd` for peak weekly use rather than autoscaling it, and
  Coder's [validated architectures](https://coder.com/docs/install/plan/sizing) give sizes
  for a number of users.
- **Workspace builds.** Each provisioner runs one build at a time. The built-in provisioners
  in `coderd` default to three (`CODER_PROVISIONER_DAEMONS`, in the
  [server reference](https://coder.com/docs/reference/cli/server#--provisioner-daemons));
  raise it if builds queue. Coder recommends
  [external provisioners](https://coder.com/docs/install/operate/provisioners), a Premium
  feature, to scale builds apart from the control plane.
- **The database.** Coder's
  [Kubernetes install guide](https://coder.com/docs/install/server/kubernetes#managed-postgresql-recommended)
  recommends a managed PostgreSQL, such as
  [Amazon RDS for PostgreSQL](https://aws.amazon.com/rds/postgresql/), and calls in-cluster
  PostgreSQL a proof-of-concept setup. Point `CODER_PG_CONNECTION_URL` at it, and Keycloak's
  `KC_DB_*` settings at a managed database too: Keycloak lists PostgreSQL and Amazon Aurora
  PostgreSQL among its [supported databases](https://www.keycloak.org/server/db).
- **Workspace capacity.** EKS Auto Mode launches sandbox-capable nodes as workspaces need
  them, and a node pool's `limits` caps the CPU and memory it may launch (Amazon EKS User
  Guide, [*Create a Node Pool for EKS Auto Mode*](https://docs.aws.amazon.com/eks/latest/userguide/create-node-pool.html)).
  Each workspace reserves its full memory request, and a node runs at most five times its
  vCPU count in sandboxes (Amazon EKS User Guide,
  [*Considerations*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-limitations.html),
  "Pod density"). If you pack many workspaces onto each node, Coder's Scale Coder guide
  suggests a separate node pool for them, away from the control plane and PostgreSQL, and
  watching your account's quotas as the number of workspaces grows.

## Good to know

- **code-server is a path-based app.** It opens at a path on the dashboard's own address,
  because a subdomain app needs a wildcard access URL, and the distribution's default
  `dXXXX.cloudfront.net` name has none. Coder's
  [server reference](https://coder.com/docs/reference/cli/server#--disable-path-apps) warns:
  "Path-based apps can make requests to the Coder API and pose a security risk when the
  workspace serves malicious JavaScript." So a page a workspace serves runs on Coder's own
  origin, where it can call the Coder API as whoever has it open: the developer, or an owner
  who opens that developer's app. Turning path-based apps off would turn code-server off too
  in this blueprint. To serve apps from subdomains instead, give the distribution a domain of
  your own with a wildcard certificate and set
  [`CODER_WILDCARD_ACCESS_URL`](https://coder.com/docs/admin/networking/wildcard-access-url).
- **The Coder admin can open every workspace.** By default the owner role has terminal, SSH
  and app access to all workspaces;
  [`CODER_DISABLE_OWNER_WORKSPACE_ACCESS`](https://coder.com/docs/reference/cli/server#--disable-owner-workspace-access)
  removes it.
- **An idle WebSocket closes after 10 minutes.** CloudFront closes a WebSocket when nothing has
  come from the origin for 10 minutes
  ([CloudFront quotas](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html#limits-websockets)),
  and the client has to reconnect. Coder's web terminal sends a ping every 15 seconds
  ([`coderd/httpapi/websocket.go`](https://github.com/coder/coder/blob/v2.38.10/coderd/httpapi/websocket.go)),
  so it never looks idle. The ALB's idle timeout is set to the same 10 minutes, so it is not
  the one to cut a connection first.
- **This blueprint does not restrict where the pod can connect.** Each workspace has a
  network, so it reaches what any pod on the cluster reaches, the internet included, and so
  does anything a developer or Claude Code runs in it. What the blueprint does limit is the
  sandbox boundary, the Pod Identity role and the provisioner's namespaced Role. To restrict
  the workspaces' network, see the
  [network policy](../../isolation/network-policy/README.md) blueprint.
- **Keep only Coder workspaces in the workspace namespace.** Kubernetes RBAC selects by
  resource type, so the provisioner's Role reaches every Deployment and claim in
  `coder-workspaces`, not only the ones Coder made.
- **The control-plane pods set requests and memory limits.** `coderd`, Keycloak and PostgreSQL
  are ordinary pods that hold the deployment's state, so each reserves what it needs on its
  node and cannot grow past a memory cap. They are starting points; Coder's validated
  architectures size `coderd` for more users.
- **Clean up leaves two security groups it does not own.** Auto Mode creates a shared backend
  security group for the cluster's load balancers, `k8s-traffic-<cluster>-<hash>`, with the
  first one, and CloudFront creates `CloudFront-VPCOrigins-Service-SG` with the first VPC
  origin in the VPC. Neither belongs to this blueprint, so the clean up reports them and
  leaves them.
- **You can drop the `auto-delete=no` tag.** Every AWS resource the scripts create carries
  `ManagedBy=coder`, which is how the clean up finds them, and `auto-delete=no`, for accounts
  whose housekeeping deletes untagged resources. If yours has no such rule, remove it from the
  scripts.
- **The ALB carries EKS Auto Mode's tags, not the blueprint's.** Auto Mode creates the load
  balancer, its listener, rules and target groups from the Ingress, and tags them
  `eks:eks-cluster-name` and `ingress.eks.amazonaws.com/stack` (`coder/coder` here). It removes
  any other tag when it next updates them, and the cluster role's
  `AmazonEKSLoadBalancingPolicy` does not allow that, so a hand-added tag makes the update
  fail. To give Auto Mode's load balancers tags of your own, the Amazon EKS User Guide
  ([*Create an IngressClass to configure an Application Load Balancer*](https://docs.aws.amazon.com/eks/latest/userguide/auto-configure-alb.html))
  has you allow them on the cluster role and set `tags` in the IngressClassParams. The clean up
  removes the ALB by deleting the Ingress.

## Clean up

Run the clean up from this folder. It reads the same `.env` and the state setup kept in
`tmp/coder/state.env`:

```bash
./scripts/cleanup.sh
```

```text
TODO: output from the fresh run
```

It deletes every workspace's Deployment and home claim, the Coder release, Keycloak,
PostgreSQL and its claim, and with the claims their EBS volumes, the Ingress and with it the
ALB, the distribution, the VPC
origin, the security group `coder-alb-origin`, the Pod Identity association and the IAM role,
the `coder-alb` IngressClass and its parameters, the blueprint's `StorageClass` if setup
created one, and both namespaces. It deletes only what carries the blueprint's `ManagedBy` tag
or `app.kubernetes.io/part-of: coder` label, and exits non-zero when it skipped something or
could not confirm a delete. Most of its time goes to waiting for CloudFront: a distribution
has to be disabled and deployed before it can be deleted, and the VPC origin can go only after
that.

What stays, and why:

- `k8s-traffic-<cluster>-<hash>` and `CloudFront-VPCOrigins-Service-SG`, which belong to the
  cluster and to CloudFront.
- The `kubernetes.io/role/internal-elb` tag on your private subnets, which you added and which
  other load balancers may use.
- `tmp/coder/`, with the passwords, the CLI sessions and the generated files. Delete it
  yourself when you are done: `rm -r ../../../tmp/coder`.
- The Coder CLI on your machine.

If this is the last blueprint you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove
the namespace and the cluster.
