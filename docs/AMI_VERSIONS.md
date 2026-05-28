# EKS NVIDIA AMI verified version matrix

The EKS-optimized AL2023 NVIDIA AMI ships a tightly-coupled stack:
kernel module + driver + nvidia-container-toolkit + containerd + runc +
nodeadm. Each row below was end-to-end tested against this Terraform
stack with a non-privileged stripped CUDA workload pod
(`nvcr.io/nvidia/cuda:*-runtime`).

Pin via root variable:

```hcl
gpu_ami_release_version = "v20260512"  # see table below
```

Empty value (`""`) follows SSM `recommended` pointer — convenient for
dev, **risky for prod** (next `terraform apply` may roll the AMI under
you when AWS bumps the alias).

## Verified

| Release | k8s | containerd | toolkit | driver | nodeadm | Status | Notes |
|---|---|---|---|---|---|---|---|
| `v20260512` | 1.35 | 2.2.3 | 1.19.0 | 580.159.03 | pre-#2705 | ✅ working | Non-privileged stripped CUDA pod runs `nvidia-smi` after a one-time userdata `systemctl restart containerd && kubelet` workaround for the nodeadm pre-#2705 cgroupsPath bug. Driver injection works through the toolkit's default jit-cdi path; no legacy mode patches required. |

## How driver injection works on this stack (must read before customising)

The AMI ships **NVIDIA Container Toolkit 1.18+** which defaults to a
just-in-time CDI mode (`jit-cdi`). It is **not** the legacy prestart-hook
flow. The full chain:

1. AMI installs `nvidia-container-toolkit` and registers `nvidia` as the
   default containerd runtime
2. nodeadm renders `/etc/containerd/config.toml` from
   `config2.template.toml` with `enable_cdi = true` for k8s 1.32+
   (PR awslabs/amazon-eks-ami#2173)
3. AMI's `nvidia-cdi-refresh.service` runs `nvidia-ctk cdi generate` at
   first boot — **but the runtime, not this generated spec, is what
   workload pods rely on**
4. When a pod with `nvidia.com/gpu` resource limit is created,
   `nvidia-container-runtime` (in jit-cdi mode) generates a CDI
   specification on the fly for the requested devices and applies it to
   the OCI spec
5. runc reads the modified OCI spec and bind-mounts driver libs from
   host `/usr/lib64/`, `/usr/bin/nvidia-smi`, etc. into the container —
   visible to the application without any prestart hook execution

Because the runtime generates the CDI spec per-pod, the type-index vs
UUID mismatch that breaks the **pre-generated** CDI spec is irrelevant —
the runtime picks the right device by GPU UUID and writes a fresh spec.

### What we deliberately do NOT patch

The stack works **as long as you do nothing**. In particular, do not:

| Anti-fix | Why it breaks things |
|---|---|
| `sed -i 's/mode = "auto"/mode = "legacy"/' config.toml` | Forces toolkit back to deprecated prestart-hook flow; on containerd 2.x the hook is silently skipped for non-privileged workload pods |
| Set `enable_cdi = false` in containerd | Disables the kubelet → containerd CDI annotation pipeline that jit-cdi needs |
| Set `accept-nvidia-visible-devices-envvar-when-unprivileged = true` | Legacy-only; ignored under jit-cdi |
| `compatWithCPUManager: true` in nvidia-device-plugin chart | Makes plugin pod privileged — was only needed when legacy hook injection failed for non-privileged plugin pods |

We hit each of these in earlier rounds and they all degraded the result
to "plugin works, workload pods fail". Going back to AWS+NVIDIA defaults
is the fix.

### What we still patch (and why)

| Patch | Purpose | Removable when |
|---|---|---|
| `NodeConfig.containerd.config` injects `[runtimes.nvidia.options] SystemdCgroup = true` | nvidia-ctk's `runtime configure` step has been observed to drop `SystemdCgroup` when overlaying its config; without it, kubelet's systemd cgroup driver disagrees with runc's cgroupfs default and pod sandbox creation fails with `expected cgroupsPath to be of format "slice:prefix:name"` | Confirmed fixed in newer toolkit/AMI combinations |
| Userdata appends `systemctl restart containerd && kubelet` after `nodeadm init` | nodeadm's `EnsureRunning()` calls `StartUnit` which is a no-op when containerd is already running — the new `/etc/containerd/config.toml` is never reloaded | AMI v20260516+ contains awslabs/amazon-eks-ami#2705 (StartDaemon → RestartDaemon) |

## How to find / pick a release

```bash
# List all available releases for a k8s version
aws ssm get-parameters-by-path \
  --path "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/nvidia" \
  --recursive --query 'Parameters[].Name' --output text \
  | tr '\t' '\n' | grep image_id | sort

# Inspect what `recommended` currently points at
aws ssm get-parameter \
  --name "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/nvidia/recommended/release_version" \
  --query Parameter.Value --output text
```

## Upgrade procedure

1. Find a candidate release in SSM (above)
2. Read [release notes](https://github.com/awslabs/amazon-eks-ami/releases) for component bumps
3. Apply with the new pin in a non-prod cluster
4. End-to-end test: launch a non-privileged stripped CUDA pod
   (`nvcr.io/nvidia/cuda:12.4.1-runtime-ubuntu22.04`), exec
   `nvidia-smi -L`, expect a list of GPUs
5. Update this file with the new row
6. Roll forward production

## EFA component versions

Three independent EFA artifacts. Two are pinned in this repo; one rides
with the AMI. Bumping any of them is independent of the AMI matrix above.

| Component | Source | Pin location | Default |
|---|---|---|---|
| EFA kernel module + rdma-core | EKS GPU AMI (preinstalled) | `gpu_ami_release_version` | follows AMI |
| EFA userspace (libfabric-aws + openmpi5-aws + `fi_info`) | `https://efa-installer.amazonaws.com/aws-efa-installer-<v>.tar.gz` fetched in node userdata | `gpu_efa_installer_version` (Terraform) / `GPU_EFA_INSTALLER_VERSION` (bash) | `1.48.0` |
| `aws-efa-k8s-device-plugin` DaemonSet | `602401143452.dkr.ecr.<region>.amazonaws.com/eks/aws-efa-k8s-device-plugin` | `efa_device_plugin_version` (Terraform) / `EFA_DEVICE_PLUGIN_VERSION` (bash) | `v0.5.19` |

Userspace bump: bump the version, `terraform apply` rolls launch
templates, replace nodes (or wait for next scaling event). Verify with
`/opt/amazon/efa/bin/fi_info --version` on the node.

Plugin bump: bump the version, `terraform apply` (or rerun
`option_install_gpu_stack.sh`) rolls the DaemonSet. Verify with
`kubectl -n kube-system get ds aws-efa-k8s-device-plugin-daemonset -o jsonpath='{.spec.template.spec.containers[0].image}'`.
