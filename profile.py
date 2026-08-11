"""Provision one bare-metal host for the RASCrash artifact evaluation."""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab


UBUNTU_22_IMAGE = (
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
)

pc = portal.Context()
pc.defineParameter(
    "hardwareType",
    "CloudLab hardware type",
    portal.ParameterType.STRING,
    "node-type-from-hotcrp",
    longDescription=(
        "Enter the exact CloudLab node type provided privately through the "
        "artifact's HotCRP discussion. The profile passes this value directly "
        "to CloudLab and provisions one bare-metal Ubuntu 22.04 host."
    ),
)
params = pc.bindParameters()

request = pc.makeRequestRSpec()
node = request.RawPC("host")
node.hardware_type = params.hardwareType
node.disk_image = UBUNTU_22_IMAGE
node.routable_control_ip = True

# CloudLab's root filesystem may not have enough free space for the Ubuntu
# installer, VM disk, and experiment output. Request an ephemeral local
# filesystem that CloudLab creates and mounts before the startup service runs.
vm_storage = node.Blockstore("vm-storage", "/local/rascrash")
vm_storage.size = "60GB"

# Repository-based profiles are cloned to /local/repository. CloudLab runs
# Execute services on every boot, so bootstrap.sh must remain idempotent.
node.addService(
    pg.Execute(
        shell="bash",
        command="sudo bash /local/repository/bootstrap.sh",
    )
)

pc.printRequestRSpec(request)
