# EC2 Image Builder configurations for EKS Nitro Sandbox AMI

EC2 Image Builder configuration files for building an EKS-optimized AL2023 AMI with the Nitro
Sandbox runtime. These files drive the same pod-isolation install as the Packer path, via an
AWSTOE component over the EKS-optimized AL2023 parent image.

**Note:** The Packer path (`scripts/10-build-ami-packer.sh`) is the **primary proven flow**. This
Image Builder path is an optional alternative, authored but not run live, because Image Builder's
build phase requires the **parentInstance-from-ASG workaround** to enable Nitro Enclaves on the
build instance (see below).

## Files

| File | What it is |
|---|---|
| [`component.yaml`](component.yaml) | AWSTOE component: installs the Nitro Sandbox runtime |
| [`image-recipe.json`](image-recipe.json) | Image recipe: parent image + the component |
| [`infrastructure-config.json`](infrastructure-config.json) | Build infrastructure (enclave-capable via ASG) |
| [`distribution-config.json`](distribution-config.json) | AMI distribution and tagging |

## The enclave requirement and the ASG workaround

EC2 Image Builder's `CreateInfrastructureConfiguration` and `InstanceConfiguration` APIs have
**no enclave field** (verified against the [EC2 Image Builder API
Reference](https://docs.aws.amazon.com/imagebuilder/latest/APIReference/Welcome.html), `CreateInfrastructureConfiguration`
and `InstanceConfiguration` schemas). The **only way** to get an enclave-enabled build instance is
the **parentInstance-from-ASG path**: an Auto Scaling group whose launch template sets
`EnclaveOptions.Enabled=true`. This applies to the **build phase only**; the resulting AMI is
enclave-capable when consumed by a node group or Karpenter `EC2NodeClass` that sets
`EnclaveOptions.Enabled=true` on its own launch template.

See the AWS documentation:
- [EC2 Image Builder User Guide: Infrastructure
  configuration](https://docs.aws.amazon.com/imagebuilder/latest/userguide/manage-infra-config.html)
- [EC2 Image Builder API Reference:
  CreateInfrastructureConfiguration](https://docs.aws.amazon.com/imagebuilder/latest/APIReference/API_CreateInfrastructureConfiguration.html)

The ASG path is configured in [`infrastructure-config.json`](infrastructure-config.json) as:

```json
{
  "parentInstance": {
    "autoScalingGroup": {
      "autoScalingGroupName": "ASG_NAME_WITH_ENCLAVE_ENABLED"
    }
  }
}
```

## Using these configurations

The configurations use placeholders for account-specific values. See
`../../scripts/10-build-ami-imagebuilder.sh` (at the repository root) for a
reference driver that substitutes them and runs the pipeline via the `aws imagebuilder` CLI.

### Required placeholders

- `ACCOUNT_ID`: Your AWS account ID
- `REGION`: AWS region (e.g., `us-west-2`)
- `KUBERNETES_VERSION`: EKS Kubernetes version (e.g., `1.37`)
- `KUBERNETES_BUILD_DATE`: EKS build date (e.g., `2024-11-14`)
- `FIRECRACKER_VERSION`: Firecracker version (e.g., `v1.18.0` or `latest`)
- `INSTANCE_PROFILE_NAME`: IAM instance profile for the build instance
- `SECURITY_GROUP_ID`: Security group for the build instance
- `SUBNET_ID`: Private subnet for the build instance
- `S3_BUCKET_NAME`: S3 bucket for build logs
- `SNS_TOPIC_ARN`: SNS topic for build notifications (optional)
- `ASG_NAME_WITH_ENCLAVE_ENABLED`: Auto Scaling group with `EnclaveOptions.Enabled=true` on its
  launch template

### AWSTOE component variables

The [`component.yaml`](component.yaml) AWSTOE document uses these templated variables:

- `{{ KUBERNETES_VERSION }}`: Kubernetes version (e.g., `1.37`)
- `{{ KUBERNETES_BUILD_DATE }}`: EKS build date
- `{{ FIRECRACKER_VERSION }}`: Firecracker version (`v1.18.0` or `latest`)

These are substituted by Image Builder at build time from the component parameters.

## Building the AMI

See `../../scripts/10-build-ami-imagebuilder.sh` (at the repository root) for a
reference implementation that creates the component, recipe, infrastructure configuration,
distribution configuration, and pipeline, then starts an execution.

## What the component installs

The AWSTOE component ([`component.yaml`](component.yaml)) performs the same install as the upstream
`amazon-eks-ami` `install-pod-isolation.sh` provisioner:

1. **Validate prerequisites**: Kubernetes 1.36 or 1.37
2. **Install packages**: `erofs-utils` (required by the shim)
3. **Assert host kernel**: `kernel6.18 >= 1:6.18.51` (stock AL2023 kernel with sandbox extensions)
4. **Set boot arguments**: `nitro_enclaves.mempool=95%-1G`
5. **Install Firecracker and jailer**: from the upstream GitHub release, checksum-verified
6. **Fetch and install runtime**: the `containerd-shim-nitro-sandbox-v2` from the public EKS S3
   bundle, checksum-verified
7. **Fetch guest images**: the Nitro sandbox guest EIF and disk image from the EKS S3 bundle,
   checksum-verified
8. **Install runtime config**: `/etc/containerd/nitro-sandbox.toml`, tun kernel module
9. **Install CRI proxy**: systemd service and kubelet drop-in
10. **Install NodeConfig**: `/etc/eks/nodeadm.d/10-pod-isolation.yaml` (containerd handlers,
    kubelet CRI endpoint, node label `eks.amazonaws.com/nitro-sandbox=true`)

The resulting AMI is named with a `-pod-isolation` suffix by the distribution configuration.
