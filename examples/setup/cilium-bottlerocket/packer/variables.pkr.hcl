# Variables of packer/bottlerocket.pkr.hcl. scripts/10-build-ami-packer.sh writes every value
# into one var file per run. No variable has a default, and each one is validated.

variable "region" {
  type = string
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "The region must look like us-west-2."
  }
}
variable "builder_ami_id" {
  type = string
  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.builder_ami_id))
    error_message = "The builder AMI must be an ami- ID."
  }
}
variable "instance_type" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.[0-9a-z]+$", var.instance_type))
    error_message = "The instance type must look like m8i.4xlarge."
  }
}
variable "subnet_id" {
  type = string
  validation {
    condition     = can(regex("^subnet-[0-9a-f]{8,17}$", var.subnet_id))
    error_message = "The subnet must be a subnet- ID."
  }
}
variable "security_group_id" {
  type = string
  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.security_group_id))
    error_message = "The security group must be an sg- ID."
  }
}
variable "instance_profile" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.instance_profile))
    error_message = "The instance profile name has characters that IAM refuses."
  }
}
variable "builder_root_gib" {
  type = number
  validation {
    condition     = var.builder_root_gib >= 20 && var.builder_root_gib <= 100 && floor(var.builder_root_gib) == var.builder_root_gib
    error_message = "The builder root volume must be a whole number of GiB from 20 to 100."
  }
}
variable "work_gib" {
  type = number
  validation {
    condition     = var.work_gib >= 100 && var.work_gib <= 400 && floor(var.work_gib) == var.work_gib
    error_message = "The work volume must be a whole number of GiB from 100 to 400."
  }
}
variable "os_image_gib" {
  type = number
  validation {
    condition     = var.os_image_gib >= 2 && var.os_image_gib <= 32 && floor(var.os_image_gib) == var.os_image_gib
    error_message = "The OS image size must be a whole number of GiB from 2 to 32."
  }
}
variable "data_image_gib" {
  type = number
  validation {
    condition     = var.data_image_gib >= 1 && var.data_image_gib <= 64 && floor(var.data_image_gib) == var.data_image_gib
    error_message = "The data image size must be a whole number of GiB from 1 to 64."
  }
}
variable "ami_name" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9()./_-]{3,128}$", var.ami_name))
    error_message = "The AMI name has characters that EC2 refuses."
  }
}
variable "build_name" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{3,128}$", var.build_name))
    error_message = "The build name has unexpected characters."
  }
}
variable "run_id" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{1,20}$", var.run_id))
    error_message = "The run ID must be 1 to 20 lowercase letters and digits."
  }
}
variable "managed_by" {
  type = string
  validation {
    condition     = var.managed_by == "cilium-bottlerocket-sample"
    error_message = "The ManagedBy value must be cilium-bottlerocket-sample."
  }
}
variable "sandbox_slots" {
  type = number
  validation {
    condition     = var.sandbox_slots >= 1 && var.sandbox_slots <= 250 && floor(var.sandbox_slots) == var.sandbox_slots
    error_message = "The sandbox slot count must be a whole number from 1 to 250."
  }
}
variable "pin_tags" {
  type = map(string)
  validation {
    condition     = length(var.pin_tags) == 5 && alltrue([for k in ["BottlerocketRelease", "Variant", "NitroRuntime", "GuestImage", "Firecracker"] : contains(keys(var.pin_tags), k)])
    error_message = "The pin tags must be exactly BottlerocketRelease, Variant, NitroRuntime, GuestImage and Firecracker."
  }
}
variable "ami_wait_attempts" {
  type = number
  validation {
    condition     = var.ami_wait_attempts >= 40 && var.ami_wait_attempts <= 480 && floor(var.ami_wait_attempts) == var.ami_wait_attempts
    error_message = "The AMI wait must be 40 to 480 polls of 15 seconds."
  }
}
variable "stage_driver" {
  type = string
  validation {
    condition     = can(regex("^/[^'\"\\n ]+/scripts/packer-stage\\.sh$", var.stage_driver))
    error_message = "The stage driver must be an absolute path to scripts/packer-stage.sh with no quote, space or newline."
  }
}
variable "run_state_dir" {
  type = string
  validation {
    condition     = can(regex("^/[^'\"\\n ]+$", var.run_state_dir))
    error_message = "The run state folder must be an absolute path with no quote, space or newline."
  }
}
variable "manifest_path" {
  type = string
  validation {
    condition     = can(regex("^/[^'\"\\n ]+/packer/manifest\\.json$", var.manifest_path))
    error_message = "The manifest must be <run>/packer/manifest.json."
  }
}
