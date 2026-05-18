#!/usr/bin/env bash
#
# Constants and Default Values
# All magic strings and default values defined here
#

# ==============================================================================
# VM IDs
# ==============================================================================

readonly DEFAULT_UBUNTU_TEMPLATE_ID="9000"
readonly DEFAULT_GOLDEN_IMAGE_TEMPLATE_ID="9100"

# ==============================================================================
# OS IMAGE VERSIONS
# ==============================================================================
# Single source of truth for every OS version referenced across the IaC.
# Bumping an OS means editing values here; every filename, URL, template
# pattern, VM name, and log message below composes from these atoms.

# Ubuntu LTS major (display strings, URL paths, template regex, VM names).
readonly UBUNTU_VERSION="24.04"
# Per-image patch versions: server and desktop ISOs track different cadences.
readonly UBUNTU_SERVER_ISO_VERSION="24.04.3"
readonly UBUNTU_DESKTOP_ISO_VERSION="24.04.1"

# Debian: major for template patterns, full for ISO filenames.
readonly DEBIAN_VERSION="13"
readonly DEBIAN_ISO_VERSION="13.1.0"

# Proxmox host runs on Debian; the no-sub repo line uses the host codename.
# Proxmox 8.x runs on bookworm — bump if you upgrade the host.
readonly PROXMOX_HOST_CODENAME="bookworm"

# Derived: VM names for cloud-init template and golden image (dot stripped).
readonly UBUNTU_TEMPLATE_VM_NAME="ubuntu-${UBUNTU_VERSION//./}-template"
readonly UBUNTU_GOLDEN_VM_NAME="ubuntu-${UBUNTU_VERSION//./}-golden"

# ==============================================================================
# NAS PATHS FOR ISO / TEMPLATE STORAGE
# ==============================================================================
# Proxmox dir storage type creates subdirectories based on content type:
#   - ISO content: stores files directly in the path (no subdirectory)
#   - vztmpl content: creates /template/cache/ subdirectory automatically
#
# Expected structure on the SMB private share (mounted at ${SMB_PRIVATE_MOUNT}):
#   ${SMB_PRIVATE_MOUNT}/images/               <- ISOs stored here directly
#   ${SMB_PRIVATE_MOUNT}/template/cache/       <- LXC templates (auto-created by Proxmox)
readonly NAS_ISO_DIR="images"          # nas-iso storage: ${SMB_PRIVATE_MOUNT}/images
readonly NAS_TEMPLATE_DIR="template"   # nas-template storage: ${SMB_PRIVATE_MOUNT}/template

# ISO Downloads - Ubuntu Server (for Packer)
readonly UBUNTU_SERVER_ISO_FILENAME="ubuntu-${UBUNTU_SERVER_ISO_VERSION}-live-server-amd64.iso"
readonly UBUNTU_SERVER_ISO_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/${UBUNTU_SERVER_ISO_FILENAME}"

# ISO Downloads - Ubuntu Desktop
readonly UBUNTU_DESKTOP_ISO_FILENAME="ubuntu-${UBUNTU_DESKTOP_ISO_VERSION}-desktop-amd64.iso"
readonly UBUNTU_DESKTOP_ISO_URL="https://releases.ubuntu.com/${UBUNTU_DESKTOP_ISO_VERSION}/${UBUNTU_DESKTOP_ISO_FILENAME}"

# ISO Downloads - Debian Netinst
readonly DEBIAN_ISO_FILENAME="debian-${DEBIAN_ISO_VERSION}-amd64-netinst.iso"
readonly DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/${DEBIAN_ISO_FILENAME}"

# LXC Template Downloads (via pveam). Dots in UBUNTU_VERSION are escaped for the regex.
readonly UBUNTU_LXC_TEMPLATE_PATTERN="ubuntu.*${UBUNTU_VERSION//./\\.}.*standard"
readonly DEBIAN_LXC_TEMPLATE_PATTERN="debian.*${DEBIAN_VERSION}.*standard"

# ==============================================================================
# UBUNTU CLOUD IMAGE
# ==============================================================================

# Default URL (can be overridden in config)
DEFAULT_UBUNTU_CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
readonly UBUNTU_CLOUD_IMAGE_FILE="/tmp/ubuntu-${UBUNTU_VERSION}-cloudimg.img"

# ==============================================================================
# NETWORK
# ==============================================================================

readonly DEFAULT_PRIVATE_NETWORK_BRIDGE="vmbr0"
readonly DEFAULT_PUBLIC_NETWORK_BRIDGE="vmbr1"
readonly DEFAULT_DNS_SERVERS="1.1.1.1 8.8.8.8"

# ==============================================================================
# STORAGE
# ==============================================================================

readonly DEFAULT_TEMPLATE_STORAGE="local-lvm"

readonly SMB_PRIVATE_CREDENTIALS="/root/.smbcredentials_private"
readonly SMB_PUBLIC_CREDENTIALS="/root/.smbcredentials_public"

# ==============================================================================
# PROXMOX REPOSITORIES
# ==============================================================================

readonly PROXMOX_ENTERPRISE_REPO_FILE="/etc/apt/sources.list.d/pve-enterprise.list"
readonly PROXMOX_NO_SUB_REPO_FILE="/etc/apt/sources.list.d/pve-no-subscription.list"
readonly PROXMOX_NO_SUB_REPO="deb http://download.proxmox.com/debian/pve ${PROXMOX_HOST_CODENAME} pve-no-subscription"

# ==============================================================================
# PATHS
# ==============================================================================

readonly PROXMOX_VERSION_FILE="/etc/pve/.version"
readonly FSTAB_FILE="/etc/fstab"
