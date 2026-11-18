# Coder template: "Claude Code on a Nitro sandbox".
#
# A platform admin publishes this template once. A developer then picks it, answers one
# question (how big the home volume is), and gets a workspace that is a single pod with
# runtimeClassName: isolated-sandbox. That pod runs inside its own Nitro guest VM. The
# workspace has Claude Code installed and set up to call Amazon Bedrock, a browser IDE
# (code-server), SSH, and a home directory on an EBS volume that survives a stop and start.
#
# Everything here works on Coder Community Edition: the Coder provider, the coder_agent,
# and the two registry modules. No license key is needed.
#
# How the workspace lifecycle maps onto Kubernetes:
#   start   The Deployment exists with one replica. A new sandbox boots and mounts the
#           same home volume claim.
#   stop    The Deployment is deleted, so the sandbox pod is deleted. The home volume
#           claim stays. State survives and the compute is freed.
#   delete  The Deployment and the home volume claim are both deleted.
#
# The setup script publishes this directory with `coder templates push` and passes the
# variables below with --variable.

terraform {
  required_providers {
    # Every version is pinned exactly, so the template builds the same way each time.
    coder = {
      source  = "coder/coder"
      version = "2.20.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Template variables. The admin sets these once per template version, with
# `coder templates push --variable name=value`. Developers never see them.
# ---------------------------------------------------------------------------

variable "namespace" {
  type        = string
  description = "Kubernetes namespace that holds the workspace pods and their home volume claims."
}

variable "service_account" {
  type        = string
  default     = "coder-workspace"
  description = "ServiceAccount the workspace pod runs as. EKS Pod Identity gives this account its Bedrock access."
}

variable "storage_class" {
  type        = string
  description = "StorageClass for the home volume claim. The setup script passes the class it chose."
}

variable "bedrock_model" {
  type        = string
  default     = "us.anthropic.claude-sonnet-5-5"
  description = "Amazon Bedrock model or inference profile ID that Claude Code uses in the workspace."
}

variable "aws_region" {
  type        = string
  description = "AWS Region where Claude Code calls Amazon Bedrock."
}

variable "workspace_image" {
  type        = string
  default     = "codercom/enterprise-base:ubuntu-20261112"
  description = "Container image for the workspace. It needs bash, curl, git and jq, and a non-root user with UID 1000."
}

variable "claude_code_version" {
  type        = string
  default     = "latest"
  description = "Claude Code version to install, for example 2.1.305. Use latest to track the newest release."
}

variable "coder_internal_url" {
  type        = string
  default     = ""
  description = "In-cluster URL of Coder, for example http://coder.coder.svc.cluster.local. Workspace agents use it instead of the public access URL. Empty means use the public access URL."

  validation {
    condition     = var.coder_internal_url == "" || can(regex("^https?://", var.coder_internal_url))
    error_message = "coder_internal_url must be empty or start with http:// or https://."
  }
}

# ---------------------------------------------------------------------------
# Providers.
# ---------------------------------------------------------------------------

# The url argument sets the address that the workspace agent uses to download its binary
# and to connect to Coder. When it is empty, the provider keeps the access URL that Coder
# passes to the provisioner. Pointing it at the in-cluster Service keeps agent traffic
# inside the cluster, so it does not go out through CloudFront and back.
provider "coder" {
  url = var.coder_internal_url != "" ? var.coder_internal_url : null
}

# The provisioner runs inside the Coder pod, so the Kubernetes provider authenticates with
# that pod's ServiceAccount token. The Role in the workspaces namespace limits what it can
# create.
provider "kubernetes" {
  config_path = null # null means in-cluster
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ---------------------------------------------------------------------------
# Parameter the developer picks when creating a workspace.
# ---------------------------------------------------------------------------

data "coder_parameter" "home_disk" {
  name         = "home_disk"
  display_name = "Home volume (GiB)"
  description  = "Persistent EBS home. It survives stop and start and is deleted with the workspace."
  type         = "number"
  default      = "10"
  mutable      = false # a claim cannot shrink, so the size is fixed when the workspace is created
  order        = 1
}

# ---------------------------------------------------------------------------
# The Coder agent: a small process Coder runs inside the workspace. The dashboard
# reaches the terminal, SSH, apps and metadata through it.
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  # Runs each time the workspace starts. Claude Code installs into ~/.local/bin. The home
  # volume starts empty, so this makes sure ~/.bashrc puts that directory on the PATH and
  # `claude` is found in the workspace terminal.
  startup_script = <<-EOT
    set -e
    if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    echo "workspace ready: $(uname -r)"
  EOT

  # Values the Coder dashboard shows for the workspace. The guest kernel proves the user
  # is inside a sandbox, because it differs from the kernel of the node.
  metadata {
    display_name = "Guest kernel"
    key          = "guest_kernel"
    script       = "uname -r"
    interval     = 60
    timeout      = 5
  }
  metadata {
    display_name = "CPU usage"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 5
  }
  metadata {
    display_name = "Home disk"
    key          = "home_disk"
    script       = "coder stat disk --path /home/coder"
    interval     = 60
    timeout      = 5
  }
}

# Claude Code reads the Region from AWS_REGION when it calls Bedrock. The claude-code
# module sets the Bedrock switch and the model but not the Region.
resource "coder_env" "aws_region" {
  agent_id = coder_agent.main.id
  name     = "AWS_REGION"
  value    = var.aws_region
}

# ---------------------------------------------------------------------------
# Modules from the Coder registry. Each one adds a script and, for code-server, an app to
# the agent. count follows the workspace state, so the scripts and apps exist only while
# the workspace is running.
# ---------------------------------------------------------------------------

# code-server: VS Code in the browser, opened from the workspace page.
module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "1.6.0"
  agent_id = coder_agent.main.id
  folder   = "/home/coder"
}

# Claude Code, installed and set up so a developer never has to install it or sign in.
# use_bedrock sets CLAUDE_CODE_USE_BEDROCK=1 and model sets ANTHROPIC_MODEL. No API key is
# involved. Claude Code finds its credentials through the standard AWS credential chain,
# which on this pod is EKS Pod Identity for the workspace ServiceAccount.
module "claude-code" {
  count               = data.coder_workspace.me.start_count
  source              = "registry.coder.com/coder/claude-code/coder"
  version             = "5.5.2"
  agent_id            = coder_agent.main.id
  workdir             = "/home/coder"
  use_bedrock         = true
  model               = var.bedrock_model
  claude_code_version = var.claude_code_version
}

# ---------------------------------------------------------------------------
# Persistent home: one ReadWriteOnce EBS volume per workspace. It has no count, so it stays
# when the workspace is stopped and is removed only when the workspace is deleted.
# ---------------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
      "com.coder.user.username"   = data.coder_workspace_owner.me.name
    }
  }

  # When the StorageClass creates the volume only after a pod first uses the claim
  # (volumeBindingMode WaitForFirstConsumer), the claim stays Pending until the workspace
  # starts. Do not wait for it to bind here.
  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk.value}Gi"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# The workspace: a Deployment with one replica while the workspace runs. Its pod is a
# Nitro sandbox.
# ---------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "workspace" {
  # One Deployment while the workspace is started, none while it is stopped. Stopping
  # deletes the sandbox pod, and starting boots a new one on the same home volume claim.
  count = data.coder_workspace.me.start_count

  # Do not hold the provisioner while the sandbox boots. The agent reports when it is ready.
  wait_for_rollout = false

  metadata {
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
      "com.coder.user.username"   = data.coder_workspace_owner.me.name
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "com.coder.workspace.id" = data.coder_workspace.me.id
      }
    }

    # The home volume can attach to one pod at a time, so the old pod must be gone before
    # the new one starts.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/part-of" = "coder"
          "com.coder.workspace.id"    = data.coder_workspace.me.id
          "com.coder.workspace.name"  = data.coder_workspace.me.name
          "com.coder.user.username"   = data.coder_workspace_owner.me.name
        }
      }

      spec {
        # This one line makes the workspace a Nitro sandbox: the pod runs in its own guest
        # VM with its own kernel instead of sharing the node's kernel.
        runtime_class_name = "isolated-sandbox"

        # EKS Pod Identity maps this ServiceAccount to an IAM role that can call Bedrock.
        # The setup script creates the ServiceAccount and the association.
        service_account_name = var.service_account

        # The workspace image runs as the user "coder" with UID 1000. fs_group makes the
        # mounted EBS volume writable by that user.
        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }

        container {
          name    = "dev"
          image   = var.workspace_image
          command = ["sh", "-c", coder_agent.main.init_script]

          security_context {
            run_as_user = 1000
            # The workspace runs as the coder user and needs no Linux capabilities, so it drops
            # all of them and cannot gain more (sudo in the image does not work here).
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          # The agent uses this token to prove to Coder that it belongs to this workspace.
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          # The guest's memory follows this memory request. It is the only size the
          # template sets: no CPU request and no limits.
          resources {
            requests = {
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }
      }
    }
  }
}
