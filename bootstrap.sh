#!/usr/bin/env bash
set -Eeuo pipefail

# CloudLab runs Execute services every time the node boots. Keep every setup
# step idempotent so reboots and power cycles do not corrupt the environment.

WORK_DIR="/local/rascrash"
LOG_DIR="${WORK_DIR}/logs"
LOG_FILE="${LOG_DIR}/setup.log"
STATE_DIR="${WORK_DIR}/state"
ISO_DIR="${WORK_DIR}/iso"
VM_DIR="${WORK_DIR}/vm"
AUTOINSTALL_DIR="${WORK_DIR}/autoinstall"

VM_NAME="rascrash-vm"
VM_VCPUS=4
VM_MEMORY_MIB=8192
# Use 40 GB—above the requested 28 GB minimum—to leave room for RAS-Strike,
# package updates, logs, and temporary experiment data.
VM_DISK_GIB=40
VM_DISK="${VM_DIR}/${VM_NAME}.qcow2"
SEED_ISO="${AUTOINSTALL_DIR}/seed.iso"

# The Ubuntu Server ISO supports Subiquity autoinstall and provides the
# terminal-only guest environment needed to run RAS-Strike.
ISO_NAME="ubuntu-22.04.5-live-server-amd64.iso"
ISO_URL="https://releases.ubuntu.com/22.04.5/${ISO_NAME}"
ISO_PATH="${ISO_DIR}/${ISO_NAME}"

# The CloudLab profile creates this ephemeral local filesystem before running
# the startup service. It avoids home-directory quotas and slow network storage.
if ! findmnt --mountpoint "${WORK_DIR}" >/dev/null 2>&1; then
    echo "ERROR: Expected CloudLab blockstore is not mounted at ${WORK_DIR}" >&2
    exit 1
fi

sudo mkdir -p \
    "${LOG_DIR}" \
    "${STATE_DIR}" \
    "${ISO_DIR}" \
    "${VM_DIR}" \
    "${AUTOINSTALL_DIR}"
sudo chmod 0755 "${WORK_DIR}" "${ISO_DIR}" "${VM_DIR}" "${AUTOINSTALL_DIR}"
exec > >(sudo tee -a "${LOG_FILE}") 2>&1

echo "Starting RASCrash artifact setup"
echo "UTC time: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# Keep this as the first package-management operation in the startup workflow.
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    xfce4 \
    xfce4-goodies \
    tigervnc-standalone-server \
    wget \
    build-essential \
    bison \
    flex \
    libncurses-dev \
    libssl-dev \
    libelf-dev \
    dwarves \
    debhelper \
    virt-manager \
    gparted \
    libdw-dev:native \
    liblz4-tool \
    qemu-kvm \
    qemu-utils \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    cloud-image-utils

# The ISO and VM disk remain on the 60 GB local CloudLab blockstore. These
# symlinks consume negligible home-directory space and only make that workspace
# available at ~/RASCrash for each interactive user.
while IFS=: read -r account _ uid gid _ home _; do
    if (( uid >= 1000 && uid < 65534 )) \
        && [[ "${home}" == /home/* || "${home}" == /users/* ]] \
        && [[ -d "${home}" ]]; then
        if [[ ! -e "${home}/RASCrash" && ! -L "${home}/RASCrash" ]]; then
            sudo ln -s "${WORK_DIR}" "${home}/RASCrash"
            sudo chown -h "${account}:${gid}" "${home}/RASCrash"
        fi
    fi
done < <(getent passwd)

sudo systemctl enable --now libvirtd
if ! sudo virsh net-info default >/dev/null 2>&1; then
    sudo virsh net-define /usr/share/libvirt/networks/default.xml
fi
if ! sudo virsh net-info default | grep -q "Active:.*yes"; then
    sudo virsh net-start default
fi
sudo virsh net-autostart default

# Download the pinned installer once. Use a temporary filename so an interrupted
# download is never mistaken for a complete ISO after a reboot.
if [[ ! -f "${ISO_PATH}" ]]; then
    sudo rm -f "${ISO_PATH}.part"
    sudo wget --progress=dot:giga --output-document="${ISO_PATH}.part" "${ISO_URL}"
    sudo mv "${ISO_PATH}.part" "${ISO_PATH}"
fi

# Reuse an existing libvirt domain after a CloudLab reboot. Installation is
# performed only when the domain has not yet been defined.
if ! sudo virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    sudo rm -f "${VM_DISK}" "${SEED_ISO}"

    # Use a fixed artifact-evaluation login to keep console access simple.
    GUEST_PASSWORD="rascrash"
    GUEST_PASSWORD_HASH="$(openssl passwd -6 "${GUEST_PASSWORD}")"
    sudo bash -c "umask 077; printf '%s\n' \
        'username=rascrash' \
        'password=${GUEST_PASSWORD}' \
        > '${WORK_DIR}/guest-credentials.txt'"

    # The storage layout uses the entire VM disk with normal installer defaults.
    sudo tee "${AUTOINSTALL_DIR}/user-data" >/dev/null <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${VM_NAME}
    username: rascrash
    password: "${GUEST_PASSWORD_HASH}"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
  updates: security
  shutdown: poweroff
EOF
    sudo tee "${AUTOINSTALL_DIR}/meta-data" >/dev/null <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF
    sudo cloud-localds \
        "${SEED_ISO}" \
        "${AUTOINSTALL_DIR}/user-data" \
        "${AUTOINSTALL_DIR}/meta-data"

    # Omitting --boot uefi, --machine, and --cpu preserves virt-install's
    # default legacy BIOS, machine, and CPU-model choices for Ubuntu 22.04.
    # The serial console avoids a graphical VM display and can be reached with
    # `sudo virsh console rascrash-vm`.
    sudo virt-install \
        --connect qemu:///system \
        --name "${VM_NAME}" \
        --virt-type kvm \
        --os-variant ubuntu22.04 \
        --vcpus "${VM_VCPUS}" \
        --memory "${VM_MEMORY_MIB}" \
        --disk "path=${VM_DISK},size=${VM_DISK_GIB},format=qcow2,bus=virtio" \
        --disk "path=${SEED_ISO},device=cdrom" \
        --network network=default,model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --location "${ISO_PATH},kernel=casper/vmlinuz,initrd=casper/initrd" \
        --extra-args "autoinstall console=ttyS0,115200n8 serial" \
        --noautoconsole \
        --wait=-1
fi

# The evaluator must attach the assigned PCIe device before the first normal
# guest boot. Explicitly disable autostart and leave the VM powered off even
# when this idempotent startup script runs again after a host reboot.
sudo virsh autostart "${VM_NAME}" --disable
VM_STATE="$(sudo virsh domstate "${VM_NAME}" | xargs)"
if [[ "${VM_STATE}" != "shut off" ]]; then
    echo "Stopping ${VM_NAME} before PCIe passthrough configuration"
    sudo virsh shutdown "${VM_NAME}" || true

    # Give Ubuntu up to two minutes to shut down cleanly.
    for ((attempt = 1; attempt <= 60; attempt++)); do
        VM_STATE="$(sudo virsh domstate "${VM_NAME}" | xargs)"
        [[ "${VM_STATE}" == "shut off" ]] && break
        sleep 2
    done

    # The freshly installed VM has no user workload. Force it off if a clean
    # shutdown did not finish so setup never exposes a running unconfigured VM.
    VM_STATE="$(sudo virsh domstate "${VM_NAME}" | xargs)"
    if [[ "${VM_STATE}" != "shut off" ]]; then
        echo "Clean shutdown timed out; forcing ${VM_NAME} off"
        sudo virsh destroy "${VM_NAME}"
    fi
fi

sudo touch "${STATE_DIR}/vm-ready-for-passthrough"
echo "VM state: $(sudo virsh domstate "${VM_NAME}" | xargs)"
echo "Next step: attach the assigned PCIe device in virt-manager; then start the VM"
echo "RASCRASH_VM_READY_FOR_PASSTHROUGH"

# TODO: Verify that the allocated node is one of the supported hardware types.
#
# TODO: Configure IOMMU/VFIO safely. Never detach the control-network device or
# a disk that contains the host root filesystem.
#
# TODO: Validate the intended PCIe device by vendor/device ID and IOMMU group,
# bind it to vfio-pci, and attach it to the guest.
#
# TODO: Configure the host's XFCE/TigerVNC session for SSH-tunneled access.
#
# TODO: Install RAS-Strike and its pinned dependencies inside the guest.
#
# TODO: Add final host, guest, and passthrough checks before creating the final
# ${STATE_DIR}/ready marker and printing RASCRASH_SETUP_READY.
