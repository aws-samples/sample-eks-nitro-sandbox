# The sandbox AMI build. One amazon-ebssurrogate source with communicator "none": Packer never
# connects to the builder. Each stage is a shell-local provisioner that runs
# scripts/packer-stage.sh. Stage bind runs on the operator machine (EC2 reads and the Systems
# Manager Online wait) and sends no command. Stage upload sends one AWS Systems Manager Run
# Command per chunk and one to unpack, and each later stage sends one.
#
# The builder is an Amazon Linux 2023 instance in a private subnet of the cluster VPC, with no
# key pair, no public IP address and a security group with no inbound rule. It writes the
# Bottlerocket OS image to /dev/xvdf and the data image to /dev/xvdb. Packer makes a snapshot of
# these two volumes only and registers the AMI with the values that Bottlerocket's pubsys tool
# uses for the aws-k8s variants. The builder root (/dev/xvda) and the work volume (/dev/xvdc)
# are omitted from the AMI.

packer {
  required_version = "= 1.16.2"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.4"
    }
  }
}

locals {
  run_tags = {
    Name      = var.build_name
    ManagedBy = var.managed_by
    RunId     = var.run_id
  }
  image_tags = merge(var.pin_tags, {
    Name         = var.ami_name
    ManagedBy    = var.managed_by
    RunId        = var.run_id
    SandboxSlots = format("%d", var.sandbox_slots)
  })
}

source "amazon-ebssurrogate" "bottlerocket" {
  region        = var.region
  source_ami    = var.builder_ami_id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  associate_public_ip_address = false
  security_group_id           = var.security_group_id
  iam_instance_profile        = var.instance_profile

  # No SSH: no communicator, so no key pair and no inbound rule.
  communicator            = "none"
  ssh_agent_auth          = true
  skip_metadata_api_check = true

  shutdown_behavior     = "stop"
  disable_stop_instance = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # The builder root: omitted from the AMI.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = var.builder_root_gib
    delete_on_termination = true
    omit_from_artifact    = true
  }
  # The work volume for the clone and the Twoliter build: omitted from the AMI.
  launch_block_device_mappings {
    device_name           = "/dev/xvdc"
    volume_type           = "gp3"
    volume_size           = var.work_gib
    delete_on_termination = true
    omit_from_artifact    = true
  }
  # The Bottlerocket OS image. It becomes the AMI root, /dev/xvda.
  launch_block_device_mappings {
    device_name           = "/dev/xvdf"
    volume_type           = "gp3"
    volume_size           = var.os_image_gib
    delete_on_termination = true
  }
  # The Bottlerocket data image. It stays /dev/xvdb in the AMI.
  launch_block_device_mappings {
    device_name           = "/dev/xvdb"
    volume_type           = "gp3"
    volume_size           = var.data_image_gib
    delete_on_termination = true
  }

  ami_root_device {
    source_device_name    = "/dev/xvdf"
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = var.os_image_gib
    delete_on_termination = true
  }

  ami_name                = var.ami_name
  ami_description         = "Bottlerocket aws-k8s-1.36-nitro-sandbox (cilium-bottlerocket sample)"
  ami_architecture        = "x86_64"
  ami_virtualization_type = "hvm"
  ena_support             = true
  sriov_support           = true
  imds_support            = "v2.0"
  # No uefi_data: one Packer pass cannot include the UEFI variables that the build makes,
  # so the firmware does not enforce Secure Boot.
  boot_mode = "uefi-preferred"

  aws_polling {
    delay_seconds = 15
    max_attempts  = var.ami_wait_attempts
  }

  run_tags        = local.run_tags
  run_volume_tags = local.run_tags
  tags            = local.image_tags
  snapshot_tags   = local.image_tags
}

build {
  sources = ["source.amazon-ebssurrogate.bottlerocket"]

  # One provisioner per stage, in this order. bash replaces the shell (exec), so a Packer
  # timeout or cancel signals the stage driver itself.
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "bind", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "15m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "upload", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "15m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "host-setup", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "30m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "fetch-verify", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "30m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "overlay", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "15m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "build", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "150m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "write-images", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "20m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "verify-root", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "15m"
  }
  provisioner "shell-local" {
    inline  = ["exec bash '${var.stage_driver}'"]
    env     = { CB_STAGE = "release", CB_BUILDER_ID = build.ID, CB_PACKER_RUN_UUID = build.PackerRunUUID, RUN_STATE_DIR = var.run_state_dir }
    timeout = "5m"
  }

  post-processor "manifest" {
    output      = var.manifest_path
    strip_path  = true
    custom_data = { run_id = var.run_id }
  }
}
