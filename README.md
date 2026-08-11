# RASCrash CloudLab Profile

This repository contains the CloudLab profile and startup script used to
prepare the host and Ubuntu VM for the RASCrash artifact evaluation.

## Repository contents

- `profile.py` — the top-level `geni-lib` profile required by CloudLab.
- `bootstrap.sh` — the idempotent startup service executed on the provisioned
  host.

## What the profile provisions

The profile creates:

- one bare-metal x86 host;
- the CloudLab Ubuntu 22.04 standard image;
- a user-specified CloudLab hardware type;
- a routable control-network address; and
- a 60 GB ephemeral local blockstore mounted at `/local/rascrash`.

The startup script installs KVM/QEMU, libvirt, `virt-install`, virt-manager,
TigerVNC, and the host-side build dependencies. It then downloads and verifies
Ubuntu Server 22.04.5 and performs an unattended installation of
`rascrash-vm` with:

- 4 vCPUs;
- 8 GiB RAM;
- a 40 GiB sparse disk;
- a serial console; and
- username and password `rascrash`.

The script disables VM autostart and leaves the VM powered off. The evaluator
must attach the assigned PCIe device before starting the guest.

## Create the CloudLab profile

1. Log in to CloudLab and choose **Experiments → Create Experiment Profile**.
2. Select **Git Repo** as the source.
3. Enter this repository URL:
   `https://github.com/sammy17/rascrash-cloudlab-profile.git`
4. Confirm that CloudLab detects `profile.py` at the repository root.
5. Create the profile and instantiate it.
6. Enter the exact supported hardware type supplied through the artifact
   evaluation discussion.

CloudLab clones repository-based profiles to `/local/repository` and invokes
`bootstrap.sh` through the profile's startup service.

## Monitor setup

After the host boots, connect over SSH and follow the setup log:

```bash
sudo tail -f /local/rascrash/logs/setup.log
```

Setup has reached the intended pre-passthrough state when the log contains:

```text
RASCRASH_VM_READY_FOR_PASSTHROUGH
```

Confirm that the VM is powered off:

```bash
sudo virsh domstate rascrash-vm
```

The expected output is `shut off`.

## Start a host VNC session

Run these commands as the logged-in CloudLab user:

```bash
vncpasswd
vncserver :1 -localhost yes -geometry 1920x1080
vncserver -list
```

Display `:1` uses TCP port 5901. On the evaluator's local computer, create an
SSH tunnel:

```bash
ssh -L 5901:localhost:5901 CLOUDLAB_USER@CLOUDLAB_HOST
```

Connect a VNC client to `localhost:5901`, open virt-manager, attach the assigned
PCIe device to `rascrash-vm`, and only then start the VM.

## Important notes

- `/local/rascrash` is ephemeral and is deleted when the CloudLab experiment
  terminates. Copy required results elsewhere before termination.
- `~/RASCrash` is a convenience symlink to `/local/rascrash`; large files are
  not stored in the network-mounted home directory.
- Do not start the VM before attaching the assigned PCIe device.
- Do not detach the host's control-network interface or root-storage device.
- The failure-reproduction experiments can disrupt the passed-through device
  and may require rebooting or power cycling the CloudLab host.
