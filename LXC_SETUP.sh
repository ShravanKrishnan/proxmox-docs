#!/bin/bash

# Proxmox LXC Container Post-Installation Script
#
# This script performs initial setup on a new LXC container.
# It should be run as root on the Proxmox host.
#
# Usage:
# bash -c "$(curl -fsSL https://.../lxc-post-install.sh)" -- <LXC_ID>

# --- General Configuration ---
readonly COMMON_PACKAGES="sudo curl wget git htop neovim qemu-guest-agent"

# --- Tailscale Configuration ---
readonly INSTALL_TAILSCALE="true"

# --- OMV CIFS Mount Configuration ---
# Set to "true" to mount a CIFS share from OpenMediaVault.
readonly MOUNT_OMV_SHARE="true"
# Path to the credentials file on the PROXMOX HOST.
readonly CREDENTIALS_FILE="/root/common.env"
# The name of the share on the OMV server (e.g., for //omv-host/data, use "data").
readonly OMV_SHARE_NAME="data"
# The mount point path inside the LXC CONTAINER.
readonly LXC_MOUNT_POINT="/mnt/data"

# --- Script Setup ---
set -euo pipefail

# --- Color Definitions ---
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'

# --- Helper Functions for Logging ---
info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; exit 1; }

# --- Helper function to execute commands inside the LXC container ---
lxc_exec() { pct exec "$VMID" -- "$@"; }

# --- Main Task Functions ---

prepare_container() {
    info "Checking status of LXC container $VMID..."
    if ! pct status "$VMID" &>/dev/null; then
        error "LXC container with ID $VMID does not exist."
    fi

    if ! pct status "$VMID" | grep -q "running"; then
        warn "Container $VMID is not running. Attempting to start it..."
        pct start "$VMID" || error "Failed to start container $VMID."
        info "Waiting for container to boot..."; sleep 5
    fi
    success "Container $VMID is up and running."
}

detect_os() {
    info "Detecting operating system in container $VMID..."
    os_id=$(lxc_exec bash -c ". /etc/os-release && echo \$ID")
    case "$os_id" in
        debian|ubuntu) PKG_MANAGER="apt"; INSTALL_CMD="install -y"; UPDATE_CMD="update"; UPGRADE_CMD="upgrade -y";;
        alpine) PKG_MANAGER="apk"; INSTALL_CMD="add"; UPDATE_CMD="update"; UPGRADE_CMD="upgrade";;
        fedora|centos|almalinux|rocky) PKG_MANAGER="dnf"; INSTALL_CMD="install -y"; UPDATE_CMD="check-update"; UPGRADE_CMD="upgrade -y";;
        *) PKG_MANAGER=""; warn "Unsupported OS: '$os_id'. Skipping package management.";;
    esac
    if [[ -n "$PKG_MANAGER" ]]; then success "Detected OS '$os_id' with package manager: '$PKG_MANAGER'"; fi
}

update_and_install_packages() {
    if [[ -z "$PKG_MANAGER" ]]; then return; fi
    info "Updating package lists and upgrading system..."
    lxc_exec "$PKG_MANAGER" "$UPDATE_CMD"
    lxc_exec "$PKG_MANAGER" "$UPGRADE_CMD"
    info "Installing common packages: $COMMON_PACKAGES"
    lxc_exec "$PKG_MANAGER" "$INSTALL_CMD" $COMMON_PACKAGES
    success "Package management tasks complete."
}

configure_lxc_for_tun() {
    info "Configuring LXC for TUN device access..."
    local conf_file="/etc/pve/lxc/${VMID}.conf"
    local changes_made=false
    if [[ ! -f "$conf_file" ]]; then error "LXC config file not found at '$conf_file'."; return 1; fi
    local cgroup_line="lxc.cgroup2.devices.allow: c 10:200 rwm"
    local mount_line="lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
    if ! grep -qxF "$cgroup_line" "$conf_file"; then echo "$cgroup_line" >> "$conf_file"; changes_made=true; fi
    if ! grep -qxF "$mount_line" "$conf_file"; then echo "$mount_line" >> "$conf_file"; changes_made=true; fi
    if [[ "$changes_made" == "true" ]]; then success "LXC configuration updated."; return 0; else success "LXC configuration is already correct."; return 1; fi
}

install_tailscale() {
    if [[ "$INSTALL_TAILSCALE" != "true" ]]; then info "Skipping Tailscale installation as per configuration."; return; fi
    info "Installing Tailscale package inside the container..."
    if ! lxc_exec bash -c "curl -fsSL https://tailscale.com/install.sh | sh"; then error "Tailscale installation failed."; return 1; fi
    success "Tailscale package installed successfully."
    if configure_lxc_for_tun; then
        warn "LXC configuration was modified. A container reboot is required."
        info "Rebooting container $VMID to apply changes..."; pct reboot "$VMID" || error "Failed to reboot container $VMID."
        info "Waiting for container to come back online..."; sleep 10
    fi
    warn "To connect this node to your Tailnet, run 'pct enter $VMID' and then 'tailscale up'"
}

mount_omv_share() {
    if [[ "$MOUNT_OMV_SHARE" != "true" ]]; then info "Skipping OMV CIFS mount as per configuration."; return; fi
    info "Starting OMV CIFS share mount process..."

    # 1. Read credentials from the host
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then warn "Credentials file not found at '$CREDENTIALS_FILE'. Skipping CIFS mount."; return; fi
    # shellcheck source=/dev/null
    source "$CREDENTIALS_FILE"
    if [[ -z "${OMV_HOST:-}" || -z "${OMV_USERNAME:-}" || -z "${OMV_PASSWORD:-}" ]]; then
        error "OMV_HOST, OMV_USERNAME, or OMV_PASSWORD not set in '$CREDENTIALS_FILE'."; return 1
    fi
    success "Successfully loaded credentials from host."

    # 2. Install cifs-utils in the container
    info "Installing CIFS client tools in the container..."
    lxc_exec "$PKG_MANAGER" "$INSTALL_CMD" cifs-utils
    success "CIFS client tools installed."

    # 3. Create mount point inside the container
    info "Ensuring mount point '$LXC_MOUNT_POINT' exists in the container..."
    lxc_exec mkdir -p "$LXC_MOUNT_POINT"

    # 4. Create a secure credentials file inside the container
    local lxc_creds_file="/root/.omv_credentials"
    info "Creating secure credentials file at '$lxc_creds_file' in the container..."
    lxc_exec bash -c "cat > '$lxc_creds_file' <<EOF
username=$OMV_USERNAME
password=$OMV_PASSWORD
EOF"
    lxc_exec chmod 600 "$lxc_creds_file"
    success "Credentials file created and secured."

    # 5. Add the entry to /etc/fstab inside the container
    local fstab_entry="//${OMV_HOST}/${OMV_SHARE_NAME}  ${LXC_MOUNT_POINT}  cifs  credentials=${lxc_creds_file},iocharset=utf8,file_mode=0777,dir_mode=0777,uid=0,gid=0  0  0"
    info "Updating /etc/fstab in the container..."
    if lxc_exec grep -qF "//${OMV_HOST}/${OMV_SHARE_NAME}" /etc/fstab; then
        info "fstab entry already exists."
    else
        lxc_exec bash -c "echo '' >> /etc/fstab" # Add a newline for safety
        lxc_exec bash -c "echo '$fstab_entry' >> /etc/fstab"
        success "fstab entry added."
    fi

    # 6. Mount the share
    info "Attempting to mount all filesystems defined in /etc/fstab..."
    if lxc_exec mount -a; then
        success "Successfully mounted all filesystems."
    else
        error "Failed to mount filesystems. Please check the container's logs and fstab."
        return 1
    fi

    # 7. Verify the mount
    if lxc_exec mount | grep -q "$LXC_MOUNT_POINT"; then
        success "Verified that '$LXC_MOUNT_POINT' is mounted."
    else
        warn "Verification failed. Could not confirm '$LXC_MOUNT_POINT' is mounted."
    fi
}

show_summary() {
    info "--- Post-Install Summary for LXC $VMID ---"
    if lxc_exec command -v qemu-ga &> /dev/null; then
        info "Waiting for guest agent to report network information..."; sleep 5
        pct rescan --vmid "$VMID" >/dev/null
    fi
    ip_info=$(lxc_exec ip -4 a | grep "inet" | grep -v "127.0.0.1" | awk '{print $2}' | sed 's|/.*||')
    if [[ -n "$ip_info" ]]; then success "Container IP Address(es):\n$(echo "$ip_info" | sed 's/^/  /') "; else warn "Could not determine container IP address."; fi
    echo -e "\n${C_GREEN}Setup complete for container $VMID.${C_RESET}"
}

main() {
    if [[ $EUID -ne 0 ]]; then error "This script must be run as root on the Proxmox host."; fi
    if ! command -v pct &>/dev/null; then error "'pct' command not found. This script must be run on a Proxmox VE host."; fi
    if [[ $# -ne 1 ]]; then echo "Usage: bash -c \"\$(curl ...)\" -- <LXC_CONTAINER_ID>"; exit 1; fi
    readonly VMID="$1"
    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then error "Invalid LXC Container ID: '$VMID'. Must be a number."; fi

    prepare_container
    detect_os
    update_and_install_packages
    install_tailscale
    mount_omv_share
    show_summary
}

main "$@"