#!/bin/bash

# Automated disk partitioning script (alternative to Archinstall)
#   - Detect & ensure GPT partition table
#   - Two modes: clean install | reinstall (keep /home)
#   - Boot partition: 3G (FAT32)
#   - Swap partition: user-configurable, default 4G (at end of disk)
#   - Root + Home: remaining space split at 2:7 ratio (btrfs subvolumes)
#   - Format, mount, root password, user creation

set -uo pipefail

# ─── Error handling ──────────────────────────
cleanup() {
    echo -ne "\e[?25h" >&2
    echo "" >&2
    echo -e "${YELLOW}  ⚠️  Script interrupted by user.${RESET}" >&2
    exit 1
}
trap 'cleanup' INT
# ─────────────────────────────────────────────

# ─── Color definitions ───────────────────────
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
LIGHT_BLUE='\e[94m'
LIGHT_PINK='\e[95m'
RESET='\e[0m'
BOLD='\e[1m'
# ─────────────────────────────────────────────

# ─── Logo ─────────────────────────────────────
print_logo() {
    while IFS= read -r line; do
        echo -e "${LIGHT_BLUE}${line:0:48}${LIGHT_PINK}${line:48}${RESET}"
    done << 'LOGO'
88      a8P                                   88  88888888ba,
88    ,88'                                    ""  88      `"8b
88  ,88"                                          88        `8b
88,d88'       ,adPPYYba,  88,dPYba,,adPYba,   88  88         88  8b,dPPYba,   ,adPPYba,  ,adPPYYba,  88,dPYba,,adPYba,
8888"88,      ""     `Y8  88P'   "88"    "8a  88  88         88  88P'   "Y8  a8P_____88  ""     `Y8  88P'   "88"    "8a
88P   Y8b     ,adPPPPP88  88      88      88  88  88         8P  88          8PP"""""""  ,adPPPPP88  88      88      88
88     "88,   88,    ,88  88      88      88  88  88      .a8P   88          "8b,   ,aa  88,    ,88  88      88      88
88       Y8b  `"8bbdP"Y8  88      88      88  88  88888888Y"'    88           `"Ybbd8"'  `"8bbdP"Y8  88      88      88
LOGO
}

# ─── Progress tracker ───────────────────────
STEPS=(
    "Risk Disclaimer"
    "System Info"
    "Disk Selection"
    "Installation Mode"
    "Find Existing /home"
    "Confirmation"
    "GPT Check"
    "Partitioning"
    "Partition Layout"
    "Confirm Format"
    "Format Partitions"
    "Mount Partitions"
    "fstab Reference"
    "Install Base System"
    "Timezone"
    "Hostname"
    "Bootloader"
    "Services"
    "Root Password"
    "Create User"
)
TOTAL=${#STEPS[@]}

show_progress() {
    local current="$1"
    echo ""
    for i in "${!STEPS[@]}"; do
        local num=$((i))
        if (( num < current )); then
            echo -e "  ${GREEN}[✓]${RESET} Step ${num}: ${STEPS[$i]}"
        elif (( num == current )); then
            echo -e "  ${CYAN}[→]${RESET} Step ${num}: ${STEPS[$i]}"
        else
            echo -e "  [ ] Step ${num}: ${STEPS[$i]}"
        fi
    done
    echo ""
}

# ─── Helpers ─────────────────────────────────
get_part_dev() {
    local disk="$1"
    local num="$2"
    if echo "$disk" | grep -qE 'nvme|mmcblk|nbd|loop'; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

parse_gb() {
    echo "$1" | sed 's/G//'
}

# ─── Parallel execution helper ────────────────
# Usage: run_parallel "task1" "cmd1" "task2" "cmd2" ...
# Runs all commands in parallel, waits for all, reports failures
run_parallel() {
    local -a pids=()
    local -a names=()
    local failed=0

    while [[ $# -gt 0 ]]; do
        local name="$1"
        local cmd="$2"
        shift 2

        names+=("$name")
        echo "  [→] Starting: ${name} ..."
        eval "$cmd" &
        pids+=($!)
    done

    for i in "${!pids[@]}"; do
        local pid=${pids[$i]}
        local name=${names[$i]}
        if wait "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}[✓]${RESET} Done: ${name}"
        else
            echo -e "  ${RED}[✗]${RESET} Failed: ${name} (exit code $?)"
            failed=1
        fi
    done

    return $failed
}

# Wait for block device to appear (with timeout)
wait_for_device() {
    local dev="$1"
    local timeout="${2:-10}"
    local elapsed=0
    while [[ ! -b "$dev" ]] && (( elapsed < timeout )); do
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    [[ -b "$dev" ]]
}

# Trigger udev and wait for device nodes to settle
sync_partitions() {
    local disk="$1"
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2
}

# ─── Prerequisites check ─────────────────────
check_prereqs() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}  ❌ This script must be run as root!${RESET}"
        exit 1
    fi
    local cmds=(lsblk sgdisk mkfs.fat mkfs.btrfs mkswap parted bc btrfs reflector)
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}  ❌ Missing required command: $cmd${RESET}"
            exit 1
        fi
    done
}

# ─── Risk Disclaimer (Step 0) ────────────────
risk_disclaimer() {
    clear
    print_logo
    show_progress 0
    echo ""
    echo "========================================================================================================================="
    echo " Step 0: Risk Disclaimer"
    echo "========================================================================================================================="
    echo ""
    echo -e "${RED}${BOLD}  ⚠️  WARNING: DESTRUCTIVE OPERATIONS AHEAD${RESET}"
    echo ""
    echo "  This script will perform IRREVERSIBLE operations on your disk, including:"
    echo "    • Wiping partition tables"
    echo "    • Creating new partitions"
    echo "    • Formatting partitions (destroying all existing data)"
    echo ""
    echo "  By proceeding, you acknowledge that:"
    echo "    • You have BACKED UP all important data"
    echo "    • You understand the risks involved"
    echo "    • You accept FULL RESPONSIBILITY for any data loss, hardware damage,"
    echo "      system corruption, or any other consequences"
    echo "    • THE AUTHOR(S) BEAR NO LIABILITY WHATSOEVER"
    echo ""
    echo -e "${YELLOW}  USE AT YOUR OWN RISK.${RESET}"
    echo ""
    read -rp "$(echo -e "${RED}${BOLD}  Type 'I ACCEPT THE RISK' to continue, or anything else to abort: ${RESET}") " acceptance
    echo ""
    if [[ "$acceptance" != "I ACCEPT THE RISK" ]]; then
        echo -e "${GREEN}  ✓ Aborted by user.${RESET}"
        exit 0
    fi
    echo -e "${GREEN}  ✓ Risk acknowledged. Proceeding...${RESET}"
    echo ""
}

# ─── Select target disk ──────────────────────
select_disk() {
    local disk
    while true; do
        read -rp "$(echo -e "${CYAN}  Enter target disk (e.g., /dev/sda, /dev/nvme0n1): ${RESET}") " disk
        if [[ -b "$disk" ]]; then
            echo "$disk"
            return 0
        else
            echo -e "${RED}  ❌ Device $disk does not exist or is not a block device.${RESET}" >&2
        fi
    done
}

# ─── Select installation mode ────────────────
choose_mode() {
    local mode
    while true; do
        echo "" >&2
        echo "  Select installation mode:" >&2
        echo "    1) Clean install   — wipe everything, fresh system" >&2
        echo "    2) Reinstall       — keep /home, only recreate boot+swap+root" >&2
        echo "" >&2
        read -rp "$(echo -e "${CYAN}  Enter 1 or 2 (default 1): ${RESET}") " mode
        case "${mode:-1}" in
            1) echo "clean"; return 0 ;;
            2) echo "reinstall"; return 0 ;;
            *) echo -e "${YELLOW}  ⚠️  Invalid choice, enter 1 or 2.${RESET}" >&2 ;;
        esac
    done
}

# ─── Find existing home partition ────────────
find_home_part() {
    local disk="$1"

    clear
    echo -e "=========================================================================================================================\n Step 4: Find Existing /home\n=========================================================================================================================" >&2

    local home_dev
    home_dev=$(blkid -L "HOME" 2>/dev/null || true)

    if [[ -n "$home_dev" ]]; then
        echo -e "${GREEN}  ✓ Found /home by label: $home_dev${RESET}" >&2
        local num
        num=$(echo "$home_dev" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')
        echo "$num"
        return 0
    fi

    echo -e "${YELLOW}  ⚠️  Could not auto-detect /home partition by label.${RESET}" >&2
    echo "  Existing partitions on $disk:" >&2
    lsblk "$disk" -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT >&2
    echo "" >&2
    local num
    while true; do
        read -rp "$(echo -e "${CYAN}  Enter the partition NUMBER of your existing /home (e.g., 4): ${RESET}") " num
        local dev
        dev=$(get_part_dev "$disk" "$num")
        if [[ -b "$dev" ]]; then
            echo "$num"
            return 0
        else
            echo -e "${RED}  ❌ Partition $dev does not exist.${RESET}" >&2
        fi
    done
}

# ─── Confirm destructive operation ───────────
# [y/N] — default NO for safety
confirm_destructive() {
    local disk="$1"
    local mode="$2"
    echo -e "${YELLOW}  ⚠️  Target disk: $disk${RESET}"
    if [[ "$mode" == "clean" ]]; then
        echo -e "${YELLOW}  ⚠️  ALL DATA on this disk will be DESTROYED!${RESET}"
    else
        echo -e "${YELLOW}  ⚠️  Partitions boot, swap, root will be RECREATED.${RESET}"
        echo -e "${YELLOW}  ⚠️  /home will be PRESERVED (not formatted).${RESET}"
    fi
    read -rp "$(echo -e "${YELLOW}  Continue? [y/N]: ${RESET}") " ans
    case "$ans" in
        y|Y) return 0 ;;
        *) echo -e "${GREEN}  ✓ Cancelled by user.${RESET}"; exit 0 ;;
    esac
}

# ─── Ensure GPT partition table ──────────────
ensure_gpt() {
    local disk="$1"
    clear
    echo -e "=========================================================================================================================\n Step 6: GPT Check\n========================================================================================================================="
    local label
    label=$(blkid -s PTTYPE -o value "$disk" 2>/dev/null || true)
    if [[ "$label" == "gpt" ]]; then
        echo -e "${GREEN}  ✓ Disk [$disk] already uses GPT.${RESET}"
    else
        echo -e "${YELLOW}  ⚠️  Current label: ${label:-"(none)"}${RESET}"
        echo -e "${YELLOW}  ⚠️  Wiping and creating GPT table.${RESET}"
        parted -s "$disk" mklabel gpt
        echo -e "${GREEN}  ✓ GPT partition table created.${RESET}"
    fi
}

# ─── Get swap size ───────────────────────────
get_swap_size() {
    local size
    read -rp "$(echo -e "${CYAN}  Enter swap size (e.g., 4G, 2G; default 4G): ${RESET}") " size
    if [[ -z "$size" ]]; then
        echo "4G"
    else
        size="${size^^}"
        if [[ "$size" =~ ^[0-9]+G$ ]]; then
            echo "$size"
        else
            echo -e "${YELLOW}  ⚠️  Invalid format, using default 4G.${RESET}" >&2
            echo "4G"
        fi
    fi
}

# ─── Detect UEFI or BIOS ─────────────────────
detect_firmware() {
    if [[ -d /sys/firmware/efi ]]; then
        echo "uefi"
    else
        echo "bios"
    fi
}

# ─── Choose bootloader ────────────────────────
# On UEFI, user can choose between systemd-boot (default) and GRUB
# On BIOS, GRUB is the only option
choose_bootloader() {
    local firmware="$1"
    if [[ "$firmware" == "bios" ]]; then
        echo "grub"
        return 0
    fi
    local choice
    while true; do
        echo "" >&2
        echo "  Select bootloader:" >&2
        echo "    1) systemd-boot — minimal, fast, UEFI only (recommended)" >&2
        echo "    2) GRUB         — feature-rich, snapshots, themes, LUKS support" >&2
        echo "" >&2
        read -rp "$(echo -e "${CYAN}  Enter 1 or 2 (default 1): ${RESET}") " choice
        case "${choice:-1}" in
            1) echo "systemd-boot"; return 0 ;;
            2) echo "grub"; return 0 ;;
            *) echo -e "${YELLOW}  ⚠️  Invalid choice, enter 1 or 2.${RESET}" >&2 ;;
        esac
    done
}

# ─── Clean install: create all partitions ────
# Order: boot → root → home → swap (swap at end)
create_partitions_clean() {
    local disk="$1"
    local boot_size="$2"
    local swap_size="$3"
    local root_size="$4"
    local home_size="$5"
    local firmware="$6"

    clear
    echo ""
    echo "========================================================================================================================="
    echo " Step 7: Create Partitions (Clean Install)"
    echo "========================================================================================================================="

    sgdisk -Z "$disk"
    echo -e "${GREEN}  ✓ All partition data wiped.${RESET}"

    if [[ "$firmware" == "uefi" ]]; then
        sgdisk -n 1:0:+${boot_size} -t 1:ef00 -c 1:"EFI" "$disk"
        echo -e "${GREEN}  ✓ EFI System Partition (${boot_size})${RESET}"
    else
        sgdisk -n 1:0:+2M -t 1:ef02 -c 1:"BIOS_BOOT" "$disk"
        sgdisk -n 2:0:+${boot_size} -t 2:8300 -c 2:"BOOT" "$disk"
        echo -e "${GREEN}  ✓ BIOS boot + /boot (${boot_size})${RESET}"
    fi

    local idx
    [[ "$firmware" == "uefi" ]] && idx=1 || idx=2

    # root
    idx=$((idx + 1))
    sgdisk -n ${idx}:0:+${root_size} -t ${idx}:8300 -c ${idx}:"ROOT" "$disk"
    echo -e "${GREEN}  ✓ Root (${root_size})${RESET}"

    # home
    idx=$((idx + 1))
    sgdisk -n ${idx}:0:+${home_size} -t ${idx}:8300 -c ${idx}:"HOME" "$disk"
    echo -e "${GREEN}  ✓ Home (${home_size})${RESET}"

    # swap (at end, skip if size is 0)
    local swap_num
    swap_num=$(parse_gb "$swap_size")
    if (( $(echo "$swap_num > 0" | bc -l) )); then
        idx=$((idx + 1))
        sgdisk -n ${idx}:0:+${swap_size} -t ${idx}:8200 -c ${idx}:"SWAP" "$disk"
        echo -e "${GREEN}  ✓ Swap (${swap_size})${RESET}"
    else
        echo -e "${YELLOW}  ⚠️  Swap skipped (size = 0).${RESET}"
    fi

    sync_partitions "$disk"
}

# ─── Reinstall: keep home, recreate rest ─────
create_partitions_reinstall() {
    local disk="$1"
    local home_num="$2"
    local boot_size="$3"
    local swap_size="$4"
    local root_size="$5"
    local firmware="$6"

    clear
    echo ""
    echo "========================================================================================================================="
    echo " Step 7: Recreate Partitions (Keep /home #${home_num})"
    echo "========================================================================================================================="

    local home_start
    home_start=$(sgdisk -i "${home_num}" "$disk" 2>/dev/null | grep "^First sector:" | sed 's/^First sector: *\([0-9]*\).*/\1/')
    if [[ -z "$home_start" ]]; then
        echo -e "${RED}  ❌ Could not determine start sector of home partition #${home_num}.${RESET}"
        exit 1
    fi

    local avail_bytes=$((home_start * 512))
    local avail_gib
    avail_gib=$(echo "scale=2; $avail_bytes / 1073741824" | bc -l)
    echo -e "${GREEN}  ✓ Available before /home: ${avail_gib}G${RESET}"

    local swap_gb
    swap_gb=$(parse_gb "$swap_size")
    local root_gb
    root_gb=$(parse_gb "$root_size")
    local needed
    needed=$(echo "scale=2; 3 + $swap_gb + $root_gb" | bc -l)

    if (( $(echo "$avail_gib < $needed" | bc -l) )); then
        echo -e "${RED}  ❌ Not enough space! Need ${needed}G, only ${avail_gib}G available.${RESET}"
        exit 1
    fi

    for ((p = 1; p < home_num; p++)); do
        if sgdisk -i "$p" "$disk" &>/dev/null; then
            sgdisk -d "$p" "$disk"
            echo -e "${GREEN}  ✓ Deleted old partition #${p}${RESET}"
        fi
    done

    local cur=2048

    # boot
    local boot_gb
    boot_gb=$(parse_gb "$boot_size")
    local boot_sec
    boot_sec=$(echo "$boot_gb * 1024^3 / 512" | bc)
    local boot_end=$((cur + boot_sec - 1))

    if [[ "$firmware" == "uefi" ]]; then
        sgdisk -n 1:${cur}:${boot_end} -t 1:ef00 -c 1:"EFI" "$disk"
        echo -e "${GREEN}  ✓ EFI System Partition recreated (${boot_size})${RESET}"
    else
        local bios_sec=4096
        local bios_end=$((cur + bios_sec - 1))
        sgdisk -n 1:${cur}:${bios_end} -t 1:ef02 -c 1:"BIOS_BOOT" "$disk"
        cur=$((bios_end + 1))
        boot_sec=$(echo "$boot_gb * 1024^3 / 512" | bc)
        boot_end=$((cur + boot_sec - 1))
        sgdisk -n 2:${cur}:${boot_end} -t 2:8300 -c 2:"BOOT" "$disk"
        echo -e "${GREEN}  ✓ /boot partition recreated (${boot_size})${RESET}"
    fi

    cur=$((boot_end + 1))

    # swap
    local swap_sec
    swap_sec=$(echo "$swap_gb * 1024^3 / 512" | bc)
    local swap_end=$((cur + swap_sec - 1))
    if [[ "$firmware" == "uefi" ]]; then
        sgdisk -n 2:${cur}:${swap_end} -t 2:8200 -c 2:"SWAP" "$disk"
    else
        sgdisk -n 3:${cur}:${swap_end} -t 3:8200 -c 3:"SWAP" "$disk"
    fi
    echo -e "${GREEN}  ✓ Swap recreated (${swap_size})${RESET}"

    cur=$((swap_end + 1))

    # root (fill to home_start - 1)
    local root_end=$((home_start - 1))
    if [[ "$firmware" == "uefi" ]]; then
        sgdisk -n 3:${cur}:${root_end} -t 3:8300 -c 3:"ROOT" "$disk"
    else
        sgdisk -n 4:${cur}:${root_end} -t 4:8300 -c 4:"ROOT" "$disk"
    fi
    echo -e "${GREEN}  ✓ Root recreated${RESET}"

    sgdisk -t "${home_num}:8300" -c "${home_num}:HOME" "$disk" 2>/dev/null || true
    echo -e "${GREEN}  ✓ /home (partition #${home_num}) preserved.${RESET}"

    sync_partitions "$disk"
}

# ─── Format partitions (parallel where possible) ──
format_partitions() {
    local firmware="$1"
    local boot="$2"
    local swap="$3"
    local root="$4"
    local home="$5"
    local fmt_home="$6"

    clear
    echo ""
    echo "========================================================================================================================="
    echo " Step 10: Format Partitions"
    echo "========================================================================================================================="

    # Phase 1: Format all partitions in parallel
    echo "  Formatting all partitions in parallel ..."
    local -a format_cmds=()
    local -a format_names=()

    format_names+=("boot (FAT32)")
    format_cmds+=("mkfs.fat -F32 -n \"EFI\" \"$boot\"")

    if [[ -n "$swap" ]]; then
        format_names+=("swap")
        format_cmds+=("mkswap -L \"SWAP\" \"$swap\"")
    fi

    format_names+=("root (btrfs)")
    format_cmds+=("mkfs.btrfs -f -L \"ROOT\" \"$root\"")

    if [[ "$fmt_home" == "true" ]]; then
        format_names+=("home (btrfs)")
        format_cmds+=("mkfs.btrfs -f -L \"HOME\" \"$home\"")
    fi

    # Build parallel command string
    local parallel_cmd=""
    for i in "${!format_names[@]}"; do
        parallel_cmd+="\"${format_names[$i]}\" \"${format_cmds[$i]}\" "
    done

    run_parallel $parallel_cmd

    # Phase 2: Create btrfs subvolumes (depends on format completion)
    echo ""
    echo "  Creating btrfs subvolumes in parallel ..."
    local -a subvol_cmds=()
    local -a subvol_names=()

    subvol_names+=("root @ subvolume")
    subvol_cmds+=("local mnt_tmp=\$(mktemp -d); mount \"$root\" \"\$mnt_tmp\"; btrfs subvolume create \"\${mnt_tmp}/@\"; umount \"\$mnt_tmp\"; rmdir \"\$mnt_tmp\"")

    if [[ "$fmt_home" == "true" ]]; then
        subvol_names+=("home @home subvolume")
        subvol_cmds+=("local mnt_tmp=\$(mktemp -d); mount \"$home\" \"\$mnt_tmp\"; btrfs subvolume create \"\${mnt_tmp}/@home\"; umount \"\$mnt_tmp\"; rmdir \"\$mnt_tmp\"")
    fi

    local subvol_parallel=""
    for i in "${!subvol_names[@]}"; do
        subvol_parallel+="\"${subvol_names[$i]}\" \"${subvol_cmds[$i]}\" "
    done

    run_parallel $subvol_parallel

    echo -e "${GREEN}  ✓ All partitions formatted and subvolumes created.${RESET}"
}

# ─── Mount partitions ────────────────────────
mount_partitions() {
    local firmware="$1"
    local boot="$2"
    local swap="$3"
    local root="$4"
    local home="$5"
    local mnt="${6:-/mnt}"

    clear
    echo ""
    echo "========================================================================================================================="
    echo " Step 11: Mount Partitions"
    echo "========================================================================================================================="

    echo "  Mounting root (@) to ${mnt} ..."
    mount -o subvol=@ "$root" "$mnt"

    mkdir -p "${mnt}/boot" "${mnt}/home"

    echo "  Mounting boot to ${mnt}/boot ..."
    mount "$boot" "${mnt}/boot"

    # Check for @home subvolume (reinstall mode compat)
    echo "  Probing home partition for @home subvolume ..."
    local mnt_tmp
    mnt_tmp=$(mktemp -d)
    if mount "$home" "$mnt_tmp" 2>/dev/null; then
        if btrfs subvolume list "$mnt_tmp" 2>/dev/null | grep -q '@home'; then
            echo "  Mounting home (@home) to ${mnt}/home ..."
            mount -o subvol=@home "$home" "${mnt}/home"
        else
            echo -e "${YELLOW}  ⚠️  @home not found, mounting home directly${RESET}"
            mount "$home" "${mnt}/home"
        fi
        umount "$mnt_tmp"
        rmdir "$mnt_tmp"
    else
        rmdir "$mnt_tmp" 2>/dev/null
        echo -e "${YELLOW}  ⚠️  Could not probe home, mounting directly${RESET}"
        mount "$home" "${mnt}/home" 2>/dev/null || true
    fi

    if [[ -n "$swap" ]]; then
        echo "  Enabling swap ..."
        swapon "$swap"
    fi

    echo -e "${GREEN}  ✓ All partitions mounted.${RESET}"
}

# ─── Show partition result ───────────────────
show_result() {
    local disk="$1"
    local boot="$2"
    local swap="$3"
    local root="$4"
    local home="$5"
    local firmware="$6"

    clear
    echo ""
    echo "========================================================================================================================="
    echo " Step 8: Partition Layout"
    echo "========================================================================================================================="
    echo ""
    echo "  Device       Size        FS          Subvol     Mount"
    echo "  ──────────── ─────────── ─────────── ────────── ─────────────"

    # Get sizes from lsblk
    local root_size swap_size home_size boot_size
    root_size=$(lsblk -ndo SIZE "$root" 2>/dev/null || echo "")
    swap_size=$(lsblk -ndo SIZE "$swap" 2>/dev/null || echo "")
    home_size=$(lsblk -ndo SIZE "$home" 2>/dev/null || echo "")
    boot_size=$(lsblk -ndo SIZE "$boot" 2>/dev/null || echo "")

    printf "  %-12s %-11s %-11s %-10s %s\n" "$boot" "$boot_size" "FAT32" "—" "/mnt/boot"
    printf "  %-12s %-11s %-11s %-10s %s\n" "$root" "$root_size" "btrfs" "@" "/mnt"
    printf "  %-12s %-11s %-11s %-10s %s\n" "$home" "$home_size" "btrfs" "@home" "/mnt/home"
    printf "  %-12s %-11s %-11s %-10s %s\n" "$swap" "$swap_size" "swap" "—" "[SWAP]"
    echo ""
}

# ─── Generate fstab hint ─────────────────────
fstab_hint() {
    local mnt="${1:-/mnt}"
    local root="$2"
    local home="$3"
    local boot="$4"
    local swap="$5"

    clear
    echo ""
    echo "========================================================================================================================="
    echo " Step 12: fstab Reference"
    echo "========================================================================================================================="
    echo ""
    echo "  After genfstab, these entries will be in ${mnt}/etc/fstab:"
    echo ""

    # Get UUIDs
    local root_uuid home_uuid boot_uuid swap_uuid
    root_uuid=$(blkid -s UUID -o value "$root" 2>/dev/null || echo "<UUID>")
    home_uuid=$(blkid -s UUID -o value "$home" 2>/dev/null || echo "<UUID>")
    boot_uuid=$(blkid -s UUID -o value "$boot" 2>/dev/null || echo "<UUID>")
    swap_uuid=$(blkid -s UUID -o value "$swap" 2>/dev/null || echo "<UUID>")

    echo "  # <file system>    <mount point>   <type>  <options>              <dump> <pass>"
    echo "  UUID=${root_uuid}  /               btrfs   rw,subvol=@            0      0"
    echo "  UUID=${home_uuid}  /home           btrfs   rw,subvol=@home        0      0"
    echo "  UUID=${boot_uuid}  /boot           vfat    rw,defaults            0      2"
    echo "  UUID=${swap_uuid}  swap            swap    defaults               0      0"
    echo ""
    echo "  Run: genfstab -U ${mnt} > ${mnt}/etc/fstab"
    echo ""
}

# ─── Install base system (pacstrap) ────────────
install_base_system() {
    local mnt="$1"
    local firmware="$2"
    local disk="$3"
    local root_part="$4"
    local boot_part="$5"
    local swap_part="$6"
    local home_part="$7"
    local bootloader="$8"

    clear
    print_logo
    show_progress 13
    echo ""
    echo "========================================================================================================================="
    echo " Step 13: Install Base System"
    echo "========================================================================================================================="
    read -rp "$(echo -e "${YELLOW}  Install base system now? (pacstrap) [Y/n]: ${RESET}") " ans
    case "$ans" in
        n|N) echo -e "${GREEN}  ✓ Skipped system installation.${RESET}"; return 1 ;;
        *) ;;
    esac

    # ── Base packages ──
    echo ""
    echo "  Installing base system (pacstrap)..."
    echo "  Packages: base base-devel linux-zen linux-lts linux-firmware"
    echo "           + dosfstools btrfs-progs"
    echo "           + networkmanager bluez bluez-utils cups pipewire"
    echo "           + ${bootloader} bootloader packages"
    echo ""
    read -rp "$(echo -e "${CYAN}  Press Enter to start pacstrap (or Ctrl+C to abort)${RESET}") "

    # ── Update mirrors with reflector (China, with timeout) ──
    echo ""
    read -rp "$(echo -e "${YELLOW}  Update pacman mirrors with reflector? [Y/n]: ${RESET}") " ans
    case "$ans" in
        n|N) echo -e "${GREEN}  ✓ Skipped mirror update.${RESET}" ;;
        *)
            echo ">>> Updating pacman mirrors (reflector --country China, no speed test) ..."
            # --sort score: pre-computed mirror scores (no speed test, finishes in ~1-2s)
            # --latest 20:   limit to 20 most recently synced mirrors
            if timeout 15 reflector --verbose --country China --sort score --latest 20 --save /etc/pacman.d/mirrorlist 2>&1; then
                echo -e "${GREEN}  ✓ Mirrors updated (top 20 by score).${RESET}"
            else
                local rc=$?
                if [[ $rc -eq 124 ]]; then
                    echo -e "${YELLOW}  ⚠️  Reflector timed out, using existing mirrors.${RESET}"
                else
                    echo -e "${YELLOW}  ⚠️  Reflector failed (exit $rc), using existing mirrors.${RESET}"
                fi
            fi
            ;;
    esac
    echo ""

    # ── Enable parallel downloads in pacman.conf (faster pacstrap) ──
    echo ">>> Enabling parallel downloads (5) in /etc/pacman.conf ..."
    if grep -q '^ParallelDownloads' /etc/pacman.conf 2>/dev/null; then
        sed -i 's/^ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    else
        sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf
    fi
    echo -e "${GREEN}  ✓ ParallelDownloads = 5${RESET}"
    echo ""

    local pkg_base="base base-devel linux-zen linux-zen-headers linux-lts linux-lts-headers linux-firmware dosfstools btrfs-progs"
    local pkg_extra="networkmanager bluez bluez-utils cups cups-filters ghostscript pipewire pipewire-pulse wireplumber alsa-utils"
    local pkg_boot=""
    if [[ "$bootloader" == "grub" ]]; then
        pkg_boot="grub"
        [[ "$firmware" == "uefi" ]] && pkg_boot="$pkg_boot efibootmgr"
    else
        pkg_boot="efibootmgr"
    fi

    echo ">>> pacstrap -K ${mnt} ${pkg_base} ${pkg_extra} ${pkg_boot} ..."
    pacstrap -K "$mnt" $pkg_base $pkg_extra $pkg_boot
    echo -e "${GREEN}  ✓ Base system installed.${RESET}"

    # ── Generate fstab ──
    echo ">>> Generating fstab ..."
    local root_uuid home_uuid boot_uuid swap_uuid
    root_uuid=$(blkid -s UUID -o value "$root_part" 2>/dev/null)
    home_uuid=$(blkid -s UUID -o value "$home_part" 2>/dev/null)
    boot_uuid=$(blkid -s UUID -o value "$boot_part" 2>/dev/null)
    swap_uuid=$(blkid -s UUID -o value "$swap_part" 2>/dev/null)

    cat > "${mnt}/etc/fstab" << FSTAB
# /etc/fstab: static file system information
# Generated by arch_partition.sh

UUID=${root_uuid}  /        btrfs  rw,noatime,subvol=@      0 0
UUID=${home_uuid}  /home    btrfs  rw,noatime,subvol=@home  0 0
UUID=${boot_uuid}  /boot    vfat   rw,noatime,fmask=0022,dmask=0022       0 2
UUID=${swap_uuid}  swap     swap   defaults                               0 0
FSTAB
    echo -e "${GREEN}  ✓ fstab generated (manual, subvol=@ / subvol=@home).${RESET}"

    # ── Console keymap ──
    echo "KEYMAP=us" > "${mnt}/etc/vconsole.conf"
    echo -e "${GREEN}  ✓ vconsole.conf created (keymap=us).${RESET}"

    return 0
}

# ─── Configure timezone ────────────────────────
configure_timezone() {
    local mnt="$1"

    clear
    print_logo
    show_progress 14
    echo ""
    echo "========================================================================================================================="
    echo " Step 14: Timezone"
    echo "========================================================================================================================="
    local tz="Asia/Shanghai"
    read -rp "$(echo -e "${CYAN}  Enter timezone (default Asia/Shanghai): ${RESET}") " tz_input
    [[ -n "$tz_input" ]] && tz="$tz_input"
    arch-chroot "$mnt" ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    arch-chroot "$mnt" hwclock --systohc
    echo -e "${GREEN}  ✓ Timezone set to ${tz}${RESET}"

    # ── Locale (en_US.UTF-8, no prompt) ──
    echo ""
    echo "  Configuring locale en_US.UTF-8 ..."
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' "${mnt}/etc/locale.gen"
    arch-chroot "$mnt" locale-gen
    echo "LANG=en_US.UTF-8" > "${mnt}/etc/locale.conf"
    echo -e "${GREEN}  ✓ Locale set to en_US.UTF-8${RESET}"
}

# ─── Configure hostname ────────────────────────
configure_hostname() {
    local mnt="$1"

    clear
    print_logo
    show_progress 15
    echo ""
    echo "========================================================================================================================="
    echo " Step 15: Hostname"
    echo "========================================================================================================================="
    local hostname="archlinux"
    read -rp "$(echo -e "${CYAN}  Enter hostname (default archlinux): ${RESET}") " hostname_input
    [[ -n "$hostname_input" ]] && hostname="$hostname_input"
    echo "$hostname" > "${mnt}/etc/hostname"
    cat > "${mnt}/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF
    echo -e "${GREEN}  ✓ Hostname set to ${hostname}${RESET}"
}

# ─── Install bootloader ────────────────────────
install_bootloader_step() {
    local mnt="$1"
    local firmware="$2"
    local disk="$3"
    local root_part="$4"
    local bootloader="$5"

    clear
    print_logo
    show_progress 16
    echo ""
    echo "========================================================================================================================="
    echo " Step 16: Bootloader"
    echo "========================================================================================================================="
    echo -e "${CYAN}  Installing bootloader (${bootloader}) ...${RESET}"

    local root_partuuid
    root_partuuid=$(blkid -s PARTUUID -o value "$root_part" 2>/dev/null)

    if [[ "$bootloader" == "systemd-boot" ]]; then
        arch-chroot "$mnt" bootctl install
        mkdir -p "${mnt}/boot/loader/entries"
        cat > "${mnt}/boot/loader/entries/arch-zen.conf" << EOF
title   Arch Linux (Zen)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options root=PARTUUID=${root_partuuid} rw rootfstype=btrfs rootflags=subvol=@
EOF
        cat > "${mnt}/boot/loader/entries/arch-lts.conf" << EOF
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options root=PARTUUID=${root_partuuid} rw rootfstype=btrfs rootflags=subvol=@
EOF
        echo "default arch-zen.conf" > "${mnt}/boot/loader/loader.conf"
        echo "timeout 5" >> "${mnt}/boot/loader/loader.conf"
        echo -e "${GREEN}  ✓ systemd-boot installed (Zen default, LTS fallback).${RESET}"
    else
        if [[ "$firmware" == "uefi" ]]; then
            arch-chroot "$mnt" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
        else
            local disk_dev
            disk_dev=$(echo "$disk" | sed 's/[0-9]*$//; s/p$//')
            arch-chroot "$mnt" grub-install --target=i386-pc "$disk_dev"
        fi
        arch-chroot "$mnt" grub-mkconfig -o /boot/grub/grub.cfg
        echo -e "${GREEN}  ✓ GRUB installed.${RESET}"
    fi
}

# ─── Enable services (Network, Bluetooth, Print, Audio) + initramfs + sudo ──
enable_services_step() {
    local mnt="$1"

    clear
    print_logo
    show_progress 17
    echo ""
    echo "========================================================================================================================="
    echo " Step 17: Services"
    echo "========================================================================================================================="
    echo "  Enabling NetworkManager ..."
    arch-chroot "$mnt" systemctl enable NetworkManager
    echo -e "${GREEN}  ✓ NetworkManager enabled.${RESET}"

    echo "  Enabling bluetooth ..."
    arch-chroot "$mnt" systemctl enable bluetooth
    echo -e "${GREEN}  ✓ Bluetooth enabled.${RESET}"

    echo "  Enabling printing (cups) ..."
    arch-chroot "$mnt" systemctl enable cups
    echo -e "${GREEN}  ✓ Printing (cups) enabled.${RESET}"

    # ── Audio (PipeWire) ──
    echo ""
    echo "  Enabling audio (PipeWire) ..."
    arch-chroot "$mnt" systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
    echo -e "${GREEN}  ✓ Audio (PipeWire) enabled.${RESET}"

    # ── Initramfs with btrfs module ──
    echo ""
    echo "  Configuring mkinitcpio for btrfs ..."
    arch-chroot "$mnt" sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
    arch-chroot "$mnt" sed -i 's/^#MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
    echo "  Regenerating initramfs for linux-zen and linux-lts in parallel ..."
    run_parallel \
        "linux-zen initramfs"  "arch-chroot \"$mnt\" mkinitcpio -p linux-zen" \
        "linux-lts initramfs"  "arch-chroot \"$mnt\" mkinitcpio -p linux-lts"
    echo -e "${GREEN}  ✓ Initramfs regenerated.${RESET}"

    # ── Verify boot files ──
    echo "  Boot files:"
    ls -lh "${mnt}/boot/vmlinuz-"* "${mnt}/boot/initramfs-"*.img 2>/dev/null || echo -e "${YELLOW}  ⚠️  Missing boot files${RESET}"

    # ── Enable sudo for wheel group ──
    echo ""
    echo "  Enabling sudo for wheel group ..."
    arch-chroot "$mnt" sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    echo -e "${GREEN}  ✓ sudo enabled for wheel group.${RESET}"
}

# ─── Set root password (post-pacstrap) ────────
set_root_password_step() {
    local mnt="$1"

    clear
    print_logo
    show_progress 18
    echo ""
    echo "========================================================================================================================="
    echo " Step 18: Set Root Password"
    echo "========================================================================================================================="
    read -rp "$(echo -e "${YELLOW}  Set root password now? [Y/n]: ${RESET}") " ans
    case "$ans" in
        n|N) echo -e "${GREEN}  ✓ Skipped.${RESET}"; return 0 ;;
        *) ;;
    esac

    local rp1 rp2
    while true; do
        read -rsp "$(echo -e "${CYAN}  Enter root password: ${RESET}") " rp1; echo ""
        read -rsp "$(echo -e "${CYAN}  Confirm root password: ${RESET}") " rp2; echo ""
        if [[ "$rp1" != "$rp2" ]]; then
            echo -e "${YELLOW}  ⚠️  Passwords do not match.${RESET}"
        elif [[ -z "$rp1" ]]; then
            echo -e "${YELLOW}  ⚠️  Password cannot be empty.${RESET}"
        else
            echo "root:$rp1" | arch-chroot "$mnt" chpasswd
            echo -e "${GREEN}  ✓ Root password set.${RESET}"
            break
        fi
    done
}

# ─── Create user (post-pacstrap) ──────────────
create_user_step() {
    local mnt="$1"

    clear
    print_logo
    show_progress 19
    echo ""
    echo "========================================================================================================================="
    echo " Step 19: Create User"
    echo "========================================================================================================================="
    read -rp "$(echo -e "${YELLOW}  Create a new user? [Y/n]: ${RESET}") " ans
    case "$ans" in
        n|N) echo -e "${GREEN}  ✓ Skipped user creation.${RESET}"; return 0 ;;
        *) ;;
    esac

    local username up1 up2
    read -rp "$(echo -e "${CYAN}  Enter username: ${RESET}") " username
    if [[ -n "$username" ]]; then
        while true; do
            read -rsp "$(echo -e "${CYAN}  Enter password: ${RESET}") " up1; echo ""
            read -rsp "$(echo -e "${CYAN}  Confirm password: ${RESET}") " up2; echo ""
            if [[ "$up1" != "$up2" ]]; then
                echo -e "${YELLOW}  ⚠️  Passwords do not match.${RESET}"
            elif [[ -z "$up1" ]]; then
                echo -e "${YELLOW}  ⚠️  Password cannot be empty.${RESET}"
            else
                arch-chroot "$mnt" useradd -m -G wheel -s /bin/bash "$username"
                echo "$username:$up1" | arch-chroot "$mnt" chpasswd
                echo -e "${GREEN}  ✓ User '$username' created (wheel group).${RESET}"
                echo -e "${GREEN}  Run 'visudo' inside the system to enable sudo.${RESET}"
                break
            fi
        done
    fi
}

# ─── Finalize ──────────────────────────────────
finalize_install() {
    echo ""
    echo -e "${GREEN}${BOLD}  ✅ System installation completed!${RESET}"
    echo -e "${GREEN}  You can now reboot into your new system.${RESET}"
    echo ""
    read -rp "$(echo -e "${YELLOW}  Reboot now? [y/N]: ${RESET}") " ans
    case "$ans" in
        y|Y)
            echo "  Rebooting in 3 seconds ..."
            sleep 3
            reboot
            ;;
        *) echo -e "${GREEN}  ✓ You can reboot later with: reboot${RESET}" ;;
    esac
}

# ─── Main ─────────────────────────────────────
main() {
    # 0. Risk Disclaimer
    risk_disclaimer

    # 1. Prerequisites
    check_prereqs

    # 1. System info (firmware + bootloader)
    clear
    print_logo
    show_progress 1
    echo "========================================================================================================================="
    echo " Step 1: System Info"
    echo "========================================================================================================================="
    local firmware
    firmware=$(detect_firmware)
    echo ""
    local bootloader
    bootloader=$(choose_bootloader "$firmware")
    echo ""
    echo -e "${GREEN}  ✓ Firmware  : ${firmware^^}${RESET}"
    echo -e "${GREEN}  ✓ Bootloader: ${bootloader}${RESET}"
    echo ""

    # 3. Disk selection
    echo ""
    echo "========================================================================================================================="
    echo " Step 2: Disk Selection"
    echo "========================================================================================================================="
    echo ""
    echo "  Available disks:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E 'disk'
    echo ""

    local disk
    disk=$(select_disk)
    echo ""

    # 3. Installation mode
    clear
    print_logo
    show_progress 3
    echo "========================================================================================================================="
    echo " Step 3: Installation Mode"
    echo "========================================================================================================================="
    local mode
    mode=$(choose_mode)
    echo -e "${GREEN}  ✓ Mode: ${mode} install${RESET}"

    # 6. Find existing /home (reinstall mode)
    local home_num=""
    if [[ "$mode" == "reinstall" ]]; then
        echo ""
        home_num=$(find_home_part "$disk")
        echo -e "${GREEN}  ✓ Home partition number: ${home_num}${RESET}"
        echo ""
    fi

    # 7. Confirmation
    clear
    print_logo
    show_progress 5
    echo "========================================================================================================================="
    echo " Step 5: Confirmation"
    echo "========================================================================================================================="
    echo ""
    confirm_destructive "$disk" "$mode"
    echo ""

    # 8. Ensure GPT partition table
    ensure_gpt "$disk"
    echo ""

    # 7. Partitioning
    clear
    print_logo
    show_progress 7
    echo "========================================================================================================================="
    echo " Step 7: Partitioning"
    echo "========================================================================================================================="
    local boot_size="3G"
    local BOOT_PART="" SWAP_PART="" ROOT_PART="" HOME_PART=""
    local FORMAT_HOME="true"

    if [[ "$mode" == "clean" ]]; then
        local disk_bytes
        disk_bytes=$(blockdev --getsize64 "$disk")
        local disk_gib
        disk_gib=$(echo "scale=2; $disk_bytes / 1073741824" | bc -l)

        echo ""
        echo "  Partition sizing:"
        echo "    1) Auto 2:7 ratio    — root:home = 2:7 (default)"
        echo "    2) Semi-manual       — specify root size, home gets the rest"
        echo "    3) Fully manual      — specify boot, root, home, swap sizes"
        echo ""
        read -rp "$(echo -e "${CYAN}  Enter 1/2/3 (default 1): ${RESET}") " split_choice

        local swap_size swap_gb root_gb home_gb boot_gb_final

        # Ask swap size for modes 1 & 2 (mode 3 asks internally)
        if [[ "${split_choice:-1}" != "3" ]]; then
            echo ""
            swap_size=$(get_swap_size)
            swap_gb=$(parse_gb "$swap_size")
            echo -e "${GREEN}  ✓ Swap: ${swap_size}${RESET}"
            echo ""
        fi

        local remain
        if [[ "${split_choice:-1}" != "3" ]]; then
            remain=$(echo "scale=2; $disk_gib - 3 - $swap_gb" | bc -l)
        fi

        if [[ "${split_choice:-1}" != "3" ]] && (( $(echo "$remain <= 1" | bc -l) )); then
            echo -e "${RED}  ❌ Insufficient disk space! Total: ${disk_gib}G${RESET}"
            exit 1
        fi
        case "${split_choice:-1}" in
            3)
                # Fully manual: user specifies every partition size
                echo ""
                while true; do
                    read -rp "$(echo -e "${CYAN}  Enter boot size in GiB (default 3, min 0.5): ${RESET}") " boot_gb_final
                    boot_gb_final="${boot_gb_final:-3}"
                    if [[ "$boot_gb_final" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$boot_gb_final >= 0.5" | bc -l) )); then
                        break
                    else
                        echo -e "${YELLOW}  ⚠️  Invalid size. Minimum 0.5G.${RESET}"
                    fi
                done
                while true; do
                    read -rp "$(echo -e "${CYAN}  Enter swap size in GiB (default 4, 0 to skip): ${RESET}") " swap_gb
                    swap_gb="${swap_gb:-4}"
                    if [[ "$swap_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$swap_gb >= 0" | bc -l) )); then
                        break
                    else
                        echo -e "${YELLOW}  ⚠️  Invalid size. Must be >= 0.${RESET}"
                    fi
                done
                local used
                used=$(echo "scale=2; $boot_gb_final + $swap_gb" | bc -l)
                local remain_manual
                remain_manual=$(echo "scale=2; $disk_gib - $used" | bc -l)
                if (( $(echo "$remain_manual <= 1" | bc -l) )); then
                    echo -e "${RED}  ❌ Insufficient space for root+home. Remaining: ${remain_manual}G${RESET}"
                    exit 1
                fi
                while true; do
                    read -rp "$(echo -e "${CYAN}  Enter root size in GiB (available: ${remain_manual}G): ${RESET}") " root_gb
                    if [[ "$root_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$root_gb > 0" | bc -l) )) && (( $(echo "$root_gb < $remain_manual" | bc -l) )); then
                        break
                    else
                        echo -e "${YELLOW}  ⚠️  Invalid size. Must be > 0 and < ${remain_manual}G.${RESET}"
                    fi
                done
                home_gb=$(echo "scale=2; $remain_manual - $root_gb" | bc -l)
                if (( $(echo "$home_gb <= 0" | bc -l) )); then
                    echo -e "${RED}  ❌ No space left for home.${RESET}"
                    exit 1
                fi
                boot_size="${boot_gb_final}G"
                swap_size="${swap_gb}G"
                ;;
            2)
                # Semi-manual: user specifies root size, home gets the rest
                while true; do
                    read -rp "$(echo -e "${CYAN}  Enter root size in GiB (available: ${remain}G): ${RESET}") " root_gb
                    if [[ "$root_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$root_gb > 0" | bc -l) )) && (( $(echo "$root_gb < $remain" | bc -l) )); then
                        home_gb=$(echo "scale=2; $remain - $root_gb" | bc -l)
                        break
                    else
                        echo -e "${YELLOW}  ⚠️  Invalid size. Must be > 0 and < ${remain}G.${RESET}"
                    fi
                done
                ;;
            *)
                # Auto 2:7 ratio (default)
                root_gb=$(echo "scale=2; $remain * 2 / 9" | bc -l)
                home_gb=$(echo "scale=2; $remain * 7 / 9" | bc -l)
                ;;
        esac

        echo "  Total : ${disk_gib}G | Boot: ${boot_size} | Swap: ${swap_size} | Root: ${root_gb}G | Home: ${home_gb}G"
        echo ""

        create_partitions_clean "$disk" "$boot_size" "$swap_size" "${root_gb}G" "${home_gb}G" "$firmware"

        if [[ "$firmware" == "uefi" ]]; then
            BOOT_PART=$(get_part_dev "$disk" 1)
            ROOT_PART=$(get_part_dev "$disk" 2)
            HOME_PART=$(get_part_dev "$disk" 3)
            if (( $(echo "$swap_gb > 0" | bc -l) )); then
                SWAP_PART=$(get_part_dev "$disk" 4)
            else
                SWAP_PART=""
            fi
        else
            BOOT_PART=$(get_part_dev "$disk" 2)
            ROOT_PART=$(get_part_dev "$disk" 3)
            HOME_PART=$(get_part_dev "$disk" 4)
            if (( $(echo "$swap_gb > 0" | bc -l) )); then
                SWAP_PART=$(get_part_dev "$disk" 5)
            else
                SWAP_PART=""
            fi
        fi
        FORMAT_HOME="true"

    else
        # Reinstall mode
        echo ""
        swap_size=$(get_swap_size)
        swap_gb=$(parse_gb "$swap_size")
        echo -e "${GREEN}  ✓ Swap: ${swap_size}${RESET}"
        echo ""

        local home_start
        home_start=$(sgdisk -i "${home_num}" "$disk" 2>/dev/null | grep "^First sector:" | sed 's/^First sector: *\([0-9]*\).*/\1/')
        local avail_bytes=$((home_start * 512))
        local avail_gib
        avail_gib=$(echo "scale=2; $avail_bytes / 1073741824" | bc -l)
        local max_root
        max_root=$(echo "scale=2; $avail_gib - 3 - $swap_gb" | bc -l)

        if (( $(echo "$max_root <= 1" | bc -l) )); then
            echo -e "${RED}  ❌ Not enough space before /home. Available: ${avail_gib}G${RESET}"
            exit 1
        fi

        local root_gb
        echo ""
        echo "  Root size (home is preserved):"
        echo "    1) Use all available: ${max_root}G (default)"
        echo "    2) Manual"
        echo ""
        read -rp "$(echo -e "${CYAN}  Enter 1 or 2 (default 1): ${RESET}") " root_choice

        case "${root_choice:-1}" in
            2)
                while true; do
                    read -rp "$(echo -e "${CYAN}  Enter root size in GiB (max: ${max_root}G): ${RESET}") " root_gb
                    if [[ "$root_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$root_gb > 0" | bc -l) )) && (( $(echo "$root_gb <= $max_root" | bc -l) )); then
                        break
                    else
                        echo -e "${YELLOW}  ⚠️  Invalid size. Must be > 0 and <= ${max_root}G.${RESET}"
                    fi
                done
                ;;
            *)
                root_gb="$max_root"
                ;;
        esac

        echo "  Available before /home : ${avail_gib}G | Boot: 3G | Swap: ${swap_size} | Root: ${root_gb}G"
        echo ""

        create_partitions_reinstall "$disk" "$home_num" "$boot_size" "$swap_size" "${root_gb}G" "$firmware"

        if [[ "$firmware" == "uefi" ]]; then
            BOOT_PART=$(get_part_dev "$disk" 1)
            SWAP_PART=$(get_part_dev "$disk" 2)
            ROOT_PART=$(get_part_dev "$disk" 3)
            HOME_PART=$(get_part_dev "$disk" "$home_num")
        else
            BOOT_PART=$(get_part_dev "$disk" 2)
            SWAP_PART=$(get_part_dev "$disk" 3)
            ROOT_PART=$(get_part_dev "$disk" 4)
            HOME_PART=$(get_part_dev "$disk" "$home_num")
        fi
        FORMAT_HOME="false"
    fi
    echo ""

    # 11. Show layout (detailed table with subvolumes)
    show_result "$disk" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART" "$HOME_PART" "$firmware"
    echo ""

    # 12. Confirm format [Y/n] (default yes)
    clear
    print_logo
    show_progress 9
    echo "========================================================================================================================="
    echo " Step 9: Confirm Format"
    echo "========================================================================================================================="
    echo ""
    local msg="Format and mount these partitions?"
    [[ "$FORMAT_HOME" == "false" ]] && msg="Format boot+swap+root and mount all (home preserved)?"
    read -rp "$(echo -e "${YELLOW}  ${msg} [Y/n]: ${RESET}") " ans
    case "$ans" in
        n|N)
            echo -e "${GREEN}  ✓ Skipped formatting. Partitions created but not formatted.${RESET}"
            exit 0
            ;;
        *) ;;
    esac
    echo ""

    # 13. Format
    format_partitions "$firmware" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART" "$HOME_PART" "$FORMAT_HOME"
    echo ""

    # 14. Mount
    mount_partitions "$firmware" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART" "$HOME_PART" "/mnt"
    echo ""

    # 15. Hint (detailed fstab reference with UUIDs)
    fstab_hint "/mnt" "$ROOT_PART" "$HOME_PART" "$BOOT_PART" "$SWAP_PART"

    # 13. Install base system (pacstrap + fstab + vconsole)
    if ! install_base_system "/mnt" "$firmware" "$disk" "$ROOT_PART" "$BOOT_PART" "$SWAP_PART" "$HOME_PART" "$bootloader"; then
        echo -e "${YELLOW}  ⚠️  Base system not installed. Exiting.${RESET}"
        exit 0
    fi

    # 14. Timezone (also locale)
    configure_timezone "/mnt"

    # 15. Hostname
    configure_hostname "/mnt"

    # 16. Bootloader
    install_bootloader_step "/mnt" "$firmware" "$disk" "$ROOT_PART" "$bootloader"

    # 17. Services (NetworkManager + Bluetooth + CUPS + PipeWire + initramfs + sudo)
    enable_services_step "/mnt"

    # 18. Root password
    set_root_password_step "/mnt"

    # 19. Create user
    create_user_step "/mnt"

    # Finalize
    finalize_install
}

# ─── Entry ────────────────────────────────────
main "$@"
