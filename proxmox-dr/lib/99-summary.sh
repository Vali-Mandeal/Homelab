#!/usr/bin/env bash
#
# Summary & Completion
# Print deployment summary
#

print_summary() {
    log_section "Deployment Complete!"

    echo "Proxmox Host: $PROXMOX_HOST_IP"
    echo ""
    echo "Templates Created:"
    echo "  - Template ${UBUNTU_TEMPLATE_ID:-9000}: ${UBUNTU_TEMPLATE_VM_NAME} (DR base, local-lvm)"
    echo "  - Template ${GOLDEN_IMAGE_TEMPLATE_ID:-9100}: ${UBUNTU_GOLDEN_VM_NAME} (Production, nas-template)"
    echo ""
    echo "Storage Mounts:"
    echo "  - NFS Public Media: ${NFS_PUBLIC_MEDIA_MOUNT}"
    echo "  - SMB Private Data: ${SMB_PRIVATE_MOUNT}"
    echo "  - SMB Public Data (SSD): ${SMB_PUBLIC_MOUNT}"
    echo ""
    echo "Next steps:"
    echo "  1. SSH to Proxmox: ssh root@${PROXMOX_HOST_IP}"
    echo "  2. Create VMs/containers as needed"
    echo ""
}
