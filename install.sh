#!/bin/bash

# Automated disk partitioning script (alternative to Archinstall)
#   - Detect & ensure GPT partition table
#   - Two modes: clean install | reinstall (keep /home)
#   - Boot partition: 3G (FAT32)
#   - Swap partition: user-configurable, default 1G (at end of disk)
#   - Root + Home: remaining space split at 2:7 ratio (btrfs subvolumes)
#   - Format, mount, root password, user creation
#   - main() uses case statement for sequential step execution

set -uo pipefail

# ═══════════════════════════════════════════════
# Error handling
# ═══════════════════════════════════════════════
cleanup() {
    echo -ne "\e[?25h" >&2
    echo "" >&2
    echo -e "${YELLOW}  ⚠️  Script interrupted by user.${RESET}" >&2
    exit 1
}
trap 'cleanup' INT

retry_or_exit() {
    local msg="${1:-Operation failed}"
    echo -e "${RED}  ❌ ${msg}${RESET}" >&2
    local ans
    while true; do
        read -rp "$(echo -e "${YELLOW}  Retry? [Y/n] (default Y): ${RESET}") " ans
        case "${ans:-y}" in
            y|Y) return 0 ;;
            n|N) echo -e "${GREEN}  ✓ Exiting by user request.${RESET}"; exit 1 ;;
        esac
    done
}

# ═══════════════════════════════════════════════
# Color definitions
# ═══════════════════════════════════════════════
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
LIGHT_BLUE='\e[94m'
LIGHT_PINK='\e[95m'
RESET='\e[0m'
BOLD='\e[1m'

# Color output helpers
success()  { echo -e "${GREEN}  ✓ ${*}${RESET}"; }
error()    { echo -e "${RED}  ❌ ${*}${RESET}" >&2; }
warning()  { echo -e "${YELLOW}  ⚠️  ${*}${RESET}" >&2; }
info()     { echo -e "${CYAN}  → ${*}${RESET}"; }
section()  { echo ""; echo "========================================================================================================================="; echo " ${*}"; echo "========================================================================================================================="; echo ""; }

# Float comparison helpers
float_gt()  { (( $(echo "$1 > $2"  | bc -l) )); }
float_lt()  { (( $(echo "$1 < $2"  | bc -l) )); }
float_le()  { (( $(echo "$1 <= $2" | bc -l) )); }
float_ge()  { (( $(echo "$1 >= $2" | bc -l) )); }

# ═══════════════════════════════════════════════
# Logo
# ═══════════════════════════════════════════════
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

# ═══════════════════════════════════════════════
# Progress tracker
# ═══════════════════════════════════════════════
STEPS=(
    "Risk Disclaimer"
    "Disk Selection (+ Firmware, Bootloader)"
    "Installation Mode"
    "Find Existing /home"
    "Confirmation"
    "GPT Check"
    "Partitioning + Layout + Confirm"
    "Format + Mount + fstab"
    "Install Base System (+Timezone, Locale)"
    "Hostname"
    "Bootloader"
    "Services"
    "Root Password"
    "Create User"
)
TOTAL=${#STEPS[@]}

# 0 = pending, 1 = completed (index matches step number)
COMPLETED=()

# Interactive step selector — ↑/↓ to navigate, Enter to execute, q to quit
# Sets global STEP_SELECTED to the chosen step number
interactive_progress() {
    local selected=0
    local key seq

    # Default: select first uncompleted step
    for i in "${!STEPS[@]}"; do
        if [[ ${COMPLETED[$i]:-0} -eq 0 ]]; then
            selected=$i
            break
        fi
    done

    echo -ne "\e[?25l"

    while true; do
        echo ""
        for i in "${!STEPS[@]}"; do
            local mark=" "
            if [[ ${COMPLETED[$i]:-0} -eq 1 ]]; then
                mark="${GREEN}✓${RESET}"
            fi

            if [[ $i -eq $selected ]]; then
                echo -e "  ${CYAN}▶${RESET} ${mark} Step ${i}: ${STEPS[$i]}"
            else
                echo -e "    ${mark} Step ${i}: ${STEPS[$i]}"
            fi
        done
        echo ""
        echo -e "  ${YELLOW}↑/↓ 导航 • Enter 执行 • q 退出${RESET}"

        read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            read -rsn2 -t 0.1 seq 2>/dev/null || true
            case "$seq" in
                '[A')  # Up
                    ((selected--))
                    [[ $selected -lt 0 ]] && selected=$((${#STEPS[@]} - 1))
                    ;;
                '[B')  # Down
                    ((selected++))
                    [[ $selected -ge ${#STEPS[@]} ]] && selected=0
                    ;;
            esac
            local total_lines=$((${#STEPS[@]} + 4))
            for ((j=0; j<total_lines; j++)); do
                echo -ne "\e[1A\e[2K"
            done
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo -ne "\e[?25h"
            echo ""
            echo -e "${GREEN}  ✓ Exited by user.${RESET}"
            exit 0
        elif [[ "$key" == "" || "$key" == $'\n' || "$key" == $'\r' ]]; then
            STEP_SELECTED=$selected
            echo -ne "\e[?25h"
            echo ""
            return 0
        fi
    done
}

# Static progress display (kept for inline context within steps)
show_progress() {
    local current="$1"
    echo ""
    for i in "${!STEPS[@]}"; do
        if [[ ${COMPLETED[$i]:-0} -eq 1 ]]; then
            echo -e "  ${GREEN}[✓]${RESET} Step ${i}: ${STEPS[$i]}"
        elif (( i == current )); then
            echo -e "  ${CYAN}[→]${RESET} Step ${i}: ${STEPS[$i]}"
        else
            echo -e "  [ ] Step ${i}: ${STEPS[$i]}"
        fi
    done
    echo ""
}

# ═══════════════════════════════════════════════
# Interactive selection menu (↑/↓ navigation)
# Usage: select_menu "prompt" "opt1" "opt2" ...
# Reads arrow keys; sets global SELECT_MENU_RESULT to 0-based index on Enter
# ═══════════════════════════════════════════════
SELECT_MENU_RESULT=0

select_menu() {
    local prompt="$1"
    shift
    local -a options=("$@")
    local opt_count=${#options[@]}
    local selected=0
    local key seq

    # Hide cursor during menu
    echo -ne "\e[?25l"

    while true; do
        # Print prompt and options
        echo ""
        echo -e "  ${prompt}"
        echo ""
        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "  ${CYAN}▶ ${options[$i]}${RESET}"
            else
                echo -e "    ${options[$i]}"
            fi
        done
        echo ""
        echo -e "  ${YELLOW}↑/↓ 导航 • Enter 确认${RESET}"

        # Read single keypress
        read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            # Escape sequence (arrow keys)
            read -rsn2 -t 0.1 seq 2>/dev/null || true
            case "$seq" in
                '[A')  # Up
                    ((selected--))
                    [[ $selected -lt 0 ]] && selected=$((opt_count - 1))
                    ;;
                '[B')  # Down
                    ((selected++))
                    [[ $selected -ge $opt_count ]] && selected=0
                    ;;
            esac
            # Move cursor up to re-render options
            local total_lines=$((opt_count + 5))
            for ((j=0; j<total_lines; j++)); do
                echo -ne "\e[1A\e[2K"
            done
        elif [[ "$key" == "" ]] || [[ "$key" == $'\n' ]] || [[ "$key" == $'\r' ]]; then
            # Enter — confirm selection
            SELECT_MENU_RESULT=$selected
            # Show cursor again
            echo -ne "\e[?25h"
            echo ""
            return 0
        fi
        # Ignore other keys
    done
}

# ═══════════════════════════════════════════════
# Multi-use helper functions
# ═══════════════════════════════════════════════

# Build partition device path (e.g., /dev/sda1, /dev/nvme0n1p1)
get_part_dev() {
    local disk="$1"
    local num="$2"
    if echo "$disk" | grep -qE 'nvme|mmcblk|nbd|loop'; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Strip 'G' suffix from size string
parse_gb() {
    echo "$1" | sed 's/G//'
}

# Parallel execution helper
# Usage: run_parallel "task1" "cmd1" "task2" "cmd2" ...
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

# Trigger udev and wait for device nodes to settle
sync_partitions() {
    local disk="$1"
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2
}

# Write domestic mirror list (instant, no network)
write_cn_mirrors() {
    cat > /etc/pacman.d/mirrorlist << 'MIRRORS'
## China Arch Linux Mirrors (direct write, no network request)
## pacman will try servers in order; failed ones are skipped automatically

Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch
Server = https://mirrors.163.com/archlinux/$repo/os/$arch
Server = https://mirrors.zju.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.sjtug.sjtu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.nju.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.hit.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.bfsu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.neusoft.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.cqu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.xjtu.edu.cn/archlinux/$repo/os/$arch
MIRRORS
}

# Prompt user for swap size, validate, return with G suffix
get_swap_size() {
    local size
    read -rp "$(echo -e "${CYAN}  Enter swap size (e.g., 1G, 2G; default 1G): ${RESET}") " size
    if [[ -z "$size" ]]; then
        echo "1G"
    else
        size="${size^^}"
        if [[ "$size" =~ ^[0-9]+G$ ]]; then
            echo "$size"
        else
            warning "Invalid format, using default 1G."
            echo "1G"
        fi
    fi
}

# ═══════════════════════════════════════════════
# Main — case-driven sequential step execution
# ═══════════════════════════════════════════════
main() {
    # ── Shared state ──
    local step=0
    local ans choice acceptance msg
    local disk="" firmware="" bootloader="" mode="" home_num=""
    local boot_size="3G" BOOT_PART="" SWAP_PART="" ROOT_PART="" HOME_PART="" FORMAT_HOME="true"
    local swap_size="" swap_gb=0 root_gb=0 home_gb=0 boot_gb_final=0
    local disk_bytes disk_gib remain max_root avail_gib avail_bytes
    local split_choice root_choice used remain_manual
    local home_start home_end root_end swap_end boot_end cur part_num
    local swap_sec boot_sec bios_sec bios_end
    local mnt_tmp mnt="/mnt"
    local root_uuid home_uuid boot_uuid swap_uuid
    local rp1 rp2 up1 up2 username hostname_input
    local root_free_kb retry max_retries pacstrap_ok
    local pkg_base pkg_extra pkg_boot
    local root_partuuid disk_dev
    local MIN_ROOT=10
    STEP_SELECTED=0
    COMPLETED=(0 0 0 0 0 0 0 0 0 0 0 0 0 0)

    while true; do
        interactive_progress
        step=$STEP_SELECTED
        case $step in
            # ─────────────────────────────────────
            0) # Risk Disclaimer + Prerequisites
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 0
                section "Step 0: Risk Disclaimer"
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
                warning "USE AT YOUR OWN RISK."
                echo ""
                read -rp "$(echo -e "${RED}${BOLD}  Continue? [y/N]: ${RESET}") " acceptance
                echo ""
                case "$acceptance" in
                    y|Y) ;;
                    *) success "Aborted by user."; exit 0 ;;
                esac
                success "Risk acknowledged. Proceeding..."
                echo ""

                # Prerequisites check (inline)
                if [[ $EUID -ne 0 ]]; then
                    error "This script must be run as root!"
                    exit 1
                fi
                local cmd
                for cmd in lsblk sgdisk mkfs.fat mkfs.btrfs mkswap parted bc btrfs; do
                    if ! command -v "$cmd" &>/dev/null; then
                        error "Missing required command: $cmd"
                        exit 1
                    fi
                done

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            1) # Disk Selection + Firmware + Bootloader
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 1
                section "Step 1: Disk Selection"

                # Collect disk options
                local -a disk_options=()
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    disk_options+=("$line")
                done < <(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null)

                if [[ ${#disk_options[@]} -eq 0 ]]; then
                    error "No disks found!"
                    exit 1
                fi

                select_menu "Select target disk:" "${disk_options[@]}"
                local selected_line="${disk_options[$SELECT_MENU_RESULT]}"
                disk="/dev/$(echo "$selected_line" | awk '{print $1}')"
                echo ""

                # Detect firmware (inline one-liner)
                if [[ -d /sys/firmware/efi ]]; then
                    firmware="uefi"
                else
                    firmware="bios"
                fi

                # Choose bootloader (inline)
                if [[ "$firmware" == "bios" ]]; then
                    bootloader="grub"
                else
                    select_menu "Select bootloader:" \
                        "systemd-boot — minimal, fast, UEFI only (recommended)" \
                        "GRUB         — feature-rich, snapshots, themes, LUKS support"
                    choice=$SELECT_MENU_RESULT
                    case $choice in
                        0) bootloader="systemd-boot" ;;
                        1) bootloader="grub" ;;
                    esac
                fi
                success "Firmware  : ${firmware^^}"
                success "Bootloader: ${bootloader}"
                echo ""

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            2) # Installation Mode
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 2
                section "Step 2: Installation Mode"

                # Choose mode (↑/↓ selection)
                select_menu "Select installation mode:" \
                    "Clean install   — wipe everything, fresh system" \
                    "Reinstall       — keep /home, only recreate boot+swap+root"
                choice=$SELECT_MENU_RESULT
                case $choice in
                    0) mode="clean" ;;
                    1) mode="reinstall" ;;
                esac
                success "Mode: ${mode} install"

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            3) # Find Existing /home (reinstall only)
            # ─────────────────────────────────────
                clear
                section "Step 3: Find Existing /home" >&2

                # Find home partition by label or manual input (inline)
                local home_dev
                home_dev=$(blkid -L "HOME" 2>/dev/null || true)

                if [[ -n "$home_dev" ]]; then
                    success "Found /home by label: $home_dev" >&2
                    home_num=$(echo "$home_dev" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')
                else
                    warning "Could not auto-detect /home partition by label." >&2
                    echo "  Existing partitions on $disk:" >&2
                    lsblk "$disk" -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT >&2
                    echo "" >&2
                    while true; do
                        read -rp "$(echo -e "${CYAN}  Enter the partition NUMBER of your existing /home (e.g., 4): ${RESET}") " home_num
                        home_dev=$(get_part_dev "$disk" "$home_num")
                        if [[ -b "$home_dev" ]]; then
                            break
                        else
                            error "Partition $home_dev does not exist." >&2
                        fi
                    done
                fi
                success "Home partition number: ${home_num}"
                echo ""

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            4) # Confirmation
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 4
                section "Step 4: Confirmation"
                warning "Target disk: $disk"
                if [[ "$mode" == "clean" ]]; then
                    warning "ALL DATA on this disk will be DESTROYED!"
                else
                    warning "Partitions boot, swap, root will be RECREATED."
                    warning "/home will be PRESERVED (not formatted)."
                fi
                read -rp "$(echo -e "${YELLOW}  Continue? [y/N]: ${RESET}") " ans
                case "$ans" in
                    y|Y) ;;
                    *) success "Cancelled by user."; exit 0 ;;
                esac

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            5) # GPT Check
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 5
                section "Step 5: GPT Check"

                local label
                label=$(blkid -s PTTYPE -o value "$disk" 2>/dev/null || true)
                if [[ "$label" == "gpt" ]]; then
                    success "Disk [$disk] already uses GPT."
                else
                    warning "Current label: ${label:-"(none)"}"
                    warning "Wiping and creating GPT table."
                    parted -s "$disk" mklabel gpt
                    success "GPT partition table created."
                fi
                echo ""

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            6) # Partitioning + Layout + Confirm
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 6
                section "Step 6: Partitioning + Layout + Confirm"

                boot_size="3G"
                BOOT_PART=""; SWAP_PART=""; ROOT_PART=""; HOME_PART=""
                FORMAT_HOME="true"

                if [[ "$mode" == "clean" ]]; then
                    # ── Clean install partitioning ──
                    disk_bytes=$(blockdev --getsize64 "$disk")
                    disk_gib=$(echo "scale=2; $disk_bytes / 1073741824" | bc -l)

                    echo ""
                    select_menu "Partition sizing:" \
                        "Auto 2:7 ratio    — root:home = 2:7 (default)" \
                        "Semi-manual       — specify root size, home gets the rest" \
                        "Fully manual      — specify boot, root, home, swap sizes"
                    choice=$SELECT_MENU_RESULT
                    case $choice in
                        0) split_choice="1" ;;
                        1) split_choice="2" ;;
                        2) split_choice="3" ;;
                    esac

                    if [[ "${split_choice:-1}" != "3" ]]; then
                        echo ""
                        swap_size=$(get_swap_size)
                        swap_gb=$(parse_gb "$swap_size")
                        success "Swap: ${swap_size}"
                        echo ""
                    fi

                    if [[ "${split_choice:-1}" != "3" ]]; then
                        local boot_gb_parsed
                        boot_gb_parsed=$(parse_gb "$boot_size")
                        remain=$(echo "scale=2; $disk_gib - $boot_gb_parsed - $swap_gb" | bc -l)
                    fi

                    if [[ "${split_choice:-1}" != "3" ]] && float_le "$remain" "1"; then
                        error "Insufficient disk space! Total: ${disk_gib}G"
                        exit 1
                    fi

                    case "${split_choice:-1}" in
                        3) # Fully manual
                            echo ""
                            while true; do
                                read -rp "$(echo -e "${CYAN}  Enter boot size in GiB (default 3, min 0.5): ${RESET}") " boot_gb_final
                                boot_gb_final="${boot_gb_final:-3}"
                                if [[ "$boot_gb_final" =~ ^[0-9]+(\.[0-9]+)?$ ]] && float_ge "$boot_gb_final" "0.5"; then
                                    break
                                else
                                    warning "Invalid size. Minimum 0.5G."
                                fi
                            done
                            while true; do
                                read -rp "$(echo -e "${CYAN}  Enter swap size in GiB (default 1, 0 to skip): ${RESET}") " swap_gb
                                swap_gb="${swap_gb:-1}"
                                if [[ "$swap_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && float_ge "$swap_gb" "0"; then
                                    break
                                else
                                    warning "Invalid size. Must be >= 0."
                                fi
                            done
                            used=$(echo "scale=2; $boot_gb_final + $swap_gb" | bc -l)
                            remain_manual=$(echo "scale=2; $disk_gib - $used" | bc -l)
                            if float_le "$remain_manual" "1"; then
                                error "Insufficient space for root+home. Remaining: ${remain_manual}G"
                                exit 1
                            fi
                            while true; do
                                read -rp "$(echo -e "${CYAN}  Enter root size in GiB (available: ${remain_manual}G): ${RESET}") " root_gb
                                if [[ "$root_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && float_gt "$root_gb" "0" && float_lt "$root_gb" "$remain_manual"; then
                                    break
                                else
                                    warning "Invalid size. Must be > 0 and < ${remain_manual}G."
                                fi
                            done
                            home_gb=$(echo "scale=2; $remain_manual - $root_gb" | bc -l)
                            if float_le "$home_gb" "0"; then
                                error "No space left for home"
                                exit 1
                            fi
                            boot_size="${boot_gb_final}G"
                            swap_size="${swap_gb}G"
                            ;;
                        2) # Semi-manual
                            while true; do
                                read -rp "$(echo -e "${CYAN}  Enter root size in GiB (available: ${remain}G): ${RESET}") " root_gb
                                if [[ "$root_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && float_gt "$root_gb" "0" && float_lt "$root_gb" "$remain"; then
                                    home_gb=$(echo "scale=2; $remain - $root_gb" | bc -l)
                                    break
                                else
                                    warning "Invalid size. Must be > 0 and < ${remain}G."
                                fi
                            done
                            ;;
                        *) # Auto 2:7
                            root_gb=$(echo "scale=2; $remain * 2 / 9" | bc -l)
                            home_gb=$(echo "scale=2; $remain * 7 / 9" | bc -l)
                            ;;
                    esac

                    echo "  Total : ${disk_gib}G | Boot: ${boot_size} | Swap: ${swap_size} | Root: ${root_gb}G | Home: ${home_gb}G"
                    echo ""

                    if float_lt "$root_gb" "$MIN_ROOT"; then
                        error "Root partition too small: ${root_gb}G < ${MIN_ROOT}G minimum"
                        error "Dual kernel (zen+lts) + base-devel + packages + pacman cache need at least ${MIN_ROOT}G."
                        warning "Try: larger disk, smaller swap, or manual sizing."
                        exit 1
                    fi

                    sgdisk -Z "$disk"
                    success "All partition data wiped."

                    local idx
                    if [[ "$firmware" == "uefi" ]]; then
                        sgdisk -n 1:0:+${boot_size} -t 1:ef00 -c 1:"EFI" "$disk"
                        success "EFI System Partition (${boot_size})"
                    else
                        sgdisk -n 1:0:+2M -t 1:ef02 -c 1:"BIOS_BOOT" "$disk"
                        sgdisk -n 2:0:+${boot_size} -t 2:8300 -c 2:"BOOT" "$disk"
                        success "BIOS boot + /boot (${boot_size})"
                    fi

                    [[ "$firmware" == "uefi" ]] && idx=1 || idx=2
                    idx=$((idx + 1))
                    sgdisk -n ${idx}:0:+${root_gb}G -t ${idx}:8300 -c ${idx}:"ROOT" "$disk"
                    success "Root (${root_gb}G)"
                    idx=$((idx + 1))
                    sgdisk -n ${idx}:0:+${home_gb}G -t ${idx}:8300 -c ${idx}:"HOME" "$disk"
                    success "Home (${home_gb}G)"

                    if float_gt "$swap_gb" "0"; then
                        idx=$((idx + 1))
                        sgdisk -n ${idx}:0:+${swap_size} -t ${idx}:8200 -c ${idx}:"SWAP" "$disk"
                        success "Swap (${swap_size})"
                    else
                        warning "Swap skipped (size = 0)."
                    fi

                    sync_partitions "$disk"

                    if [[ "$firmware" == "uefi" ]]; then
                        BOOT_PART=$(get_part_dev "$disk" 1)
                        ROOT_PART=$(get_part_dev "$disk" 2)
                        HOME_PART=$(get_part_dev "$disk" 3)
                        if float_gt "$swap_gb" "0"; then
                            SWAP_PART=$(get_part_dev "$disk" 4)
                        else
                            SWAP_PART=""
                        fi
                    else
                        BOOT_PART=$(get_part_dev "$disk" 2)
                        ROOT_PART=$(get_part_dev "$disk" 3)
                        HOME_PART=$(get_part_dev "$disk" 4)
                        if float_gt "$swap_gb" "0"; then
                            SWAP_PART=$(get_part_dev "$disk" 5)
                        else
                            SWAP_PART=""
                        fi
                    fi
                    FORMAT_HOME="true"

                else
                    # ── Reinstall partitioning ──
                    echo ""
                    swap_size=$(get_swap_size)
                    swap_gb=$(parse_gb "$swap_size")
                    success "Swap: ${swap_size}"
                    echo ""

                    home_start=$(sgdisk -i "${home_num}" "$disk" 2>/dev/null | grep "^First sector:" | sed 's/^First sector: *\([0-9]*\).*/\1/')
                    avail_bytes=$((home_start * 512))
                    avail_gib=$(echo "scale=2; $avail_bytes / 1073741824" | bc -l)
                    local boot_gb_parsed
                    boot_gb_parsed=$(parse_gb "$boot_size")
                    max_root=$(echo "scale=2; $avail_gib - $boot_gb_parsed - $swap_gb" | bc -l)

                    if float_le "$max_root" "1"; then
                        error "Not enough space before /home. Available: ${avail_gib}G"
                        exit 1
                    fi

                    echo ""
                    select_menu "Root size (home is preserved):" \
                        "Use all available: ${max_root}G (default)" \
                        "Manual"
                    choice=$SELECT_MENU_RESULT
                    case $choice in
                        0) root_choice="1" ;;
                        1) root_choice="2" ;;
                    esac

                    case "${root_choice:-1}" in
                        2)
                            while true; do
                                read -rp "$(echo -e "${CYAN}  Enter root size in GiB (max: ${max_root}G): ${RESET}") " root_gb
                                if [[ "$root_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && float_gt "$root_gb" "0" && float_le "$root_gb" "$max_root"; then
                                    break
                                else
                                    warning "Invalid size. Must be > 0 and <= ${max_root}G."
                                fi
                            done
                            ;;
                        *)
                            root_gb="$max_root"
                            ;;
                    esac

                    echo "  Available before /home : ${avail_gib}G | Boot: ${boot_size} | Swap: ${swap_size} | Root: ${root_gb}G"
                    echo ""

                    if float_lt "$root_gb" "$MIN_ROOT"; then
                        error "Root partition too small: ${root_gb}G < ${MIN_ROOT}G minimum"
                        error "Dual kernel (zen+lts) + base-devel + packages need at least ${MIN_ROOT}G."
                        exit 1
                    fi

                    # Save home sector range
                    home_start=$(sgdisk -i "${home_num}" "$disk" 2>/dev/null | grep "^First sector:" | sed 's/^First sector: *\([0-9]*\).*/\1/')
                    home_end=$(sgdisk -i "${home_num}" "$disk" 2>/dev/null   | grep "^Last sector:"  | sed 's/^Last sector: *\([0-9]*\).*/\1/')
                    if [[ -z "$home_start" || -z "$home_end" ]]; then
                        error "Could not determine sector range of home partition #${home_num}"
                        exit 1
                    fi

                    avail_bytes=$((home_start * 512))
                    avail_gib=$(echo "scale=2; $avail_bytes / 1073741824" | bc -l)
                    success "Available before /home: ${avail_gib}G"

                    local swap_gb_local root_gb_local boot_gb_local
                    swap_gb_local=$(parse_gb "$swap_size")
                    root_gb_local=$(parse_gb "${root_gb}G")
                    boot_gb_local=$(parse_gb "$boot_size")
                    local needed
                    needed=$(echo "scale=2; $boot_gb_local + $swap_gb_local + $root_gb_local" | bc -l)

                    if float_lt "$avail_gib" "$needed"; then
                        error "Not enough space! Need ${needed}G, only ${avail_gib}G available"
                        exit 1
                    fi

                    sgdisk -Z "$disk"
                    success "All partition data wiped (home sector range saved)"

                    cur=2048
                    part_num=0

                    boot_sec=$(echo "$boot_gb_local * 1024^3 / 512" | bc)
                    boot_end=$((cur + boot_sec - 1))
                    if [[ "$firmware" == "uefi" ]]; then
                        part_num=1
                        sgdisk -n ${part_num}:${cur}:${boot_end} -t ${part_num}:ef00 -c ${part_num}:"EFI" "$disk"
                        success "EFI System Partition (${boot_size})"
                    else
                        bios_sec=4096
                        bios_end=$((cur + bios_sec - 1))
                        sgdisk -n 1:${cur}:${bios_end} -t 1:ef02 -c 1:"BIOS_BOOT" "$disk"
                        cur=$((bios_end + 1))
                        boot_sec=$(echo "$boot_gb_local * 1024^3 / 512" | bc)
                        boot_end=$((cur + boot_sec - 1))
                        sgdisk -n 2:${cur}:${boot_end} -t 2:8300 -c 2:"BOOT" "$disk"
                        part_num=2
                        success "/boot partition (${boot_size})"
                    fi

                    cur=$((boot_end + 1))
                    part_num=$((part_num + 1))
                    swap_sec=$(echo "$swap_gb_local * 1024^3 / 512" | bc)
                    swap_end=$((cur + swap_sec - 1))
                    sgdisk -n ${part_num}:${cur}:${swap_end} -t ${part_num}:8200 -c ${part_num}:"SWAP" "$disk"
                    success "Swap (${swap_size})"

                    cur=$((swap_end + 1))
                    part_num=$((part_num + 1))
                    root_end=$((home_start - 1))
                    sgdisk -n ${part_num}:${cur}:${root_end} -t ${part_num}:8300 -c ${part_num}:"ROOT" "$disk"
                    success "Root (fills to sector ${root_end})"

                    part_num=$((part_num + 1))
                    sgdisk -n ${part_num}:${home_start}:${home_end} -t ${part_num}:8300 -c ${part_num}:"HOME" "$disk"
                    success "/home preserved (now partition #${part_num}, same sector range)"

                    sync_partitions "$disk"
                    home_num=$part_num

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

                # ── Show Partition Layout (inline, no separate step) ──
                echo "========================================================================================================================="
                echo " Partition Layout"
                echo "========================================================================================================================="
                echo ""
                echo "  Device       Size        FS          Subvol     Mount"
                echo "  ──────────── ─────────── ─────────── ────────── ─────────────"

                local root_size_str swap_size_str home_size_str boot_size_str
                root_size_str=$(lsblk -ndo SIZE "$ROOT_PART" 2>/dev/null || echo "")
                swap_size_str=$(lsblk -ndo SIZE "$SWAP_PART" 2>/dev/null || echo "")
                home_size_str=$(lsblk -ndo SIZE "$HOME_PART" 2>/dev/null || echo "")
                boot_size_str=$(lsblk -ndo SIZE "$BOOT_PART" 2>/dev/null || echo "")

                printf "  %-12s %-11s %-11s %-10s %s\n" "$BOOT_PART" "$boot_size_str" "FAT32" "—" "/mnt/boot"
                printf "  %-12s %-11s %-11s %-10s %s\n" "$ROOT_PART" "$root_size_str" "btrfs" "@" "/mnt"
                printf "  %-12s %-11s %-11s %-10s %s\n" "$HOME_PART" "$home_size_str" "btrfs" "@home" "/mnt/home"
                printf "  %-12s %-11s %-11s %-10s %s\n" "$SWAP_PART" "$swap_size_str" "swap" "—" "[SWAP]"
                echo ""

                # ── Proceed directly to format + mount (no confirm needed) ──
                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            7) # Format + Mount + fstab
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 7
                section "Step 7: Format + Mount + fstab"

                # ── Format all partitions in parallel ──
                echo "  Formatting all partitions in parallel ..."
                local -a f_args=()
                f_args+=("boot (FAT32)" "mkfs.fat -F32 -n EFI $BOOT_PART")
                if [[ -n "$SWAP_PART" ]]; then
                    f_args+=("swap" "mkswap -L SWAP $SWAP_PART")
                fi
                f_args+=("root (btrfs)" "mkfs.btrfs -f -L ROOT $ROOT_PART")
                if [[ "$FORMAT_HOME" == "true" ]]; then
                    f_args+=("home (btrfs)" "mkfs.btrfs -f -L HOME $HOME_PART")
                fi
                run_parallel "${f_args[@]}"

                echo ""
                echo "  Creating btrfs subvolumes in parallel ..."
                local -a s_args=()
                s_args+=("root @ subvolume" "mnt_tmp=\$(mktemp -d); mount $ROOT_PART \$mnt_tmp; btrfs subvolume create \${mnt_tmp}/@; umount \$mnt_tmp; rmdir \$mnt_tmp")
                if [[ "$FORMAT_HOME" == "true" ]]; then
                    s_args+=("home @home subvolume" "mnt_tmp=\$(mktemp -d); mount $HOME_PART \$mnt_tmp; btrfs subvolume create \${mnt_tmp}/@home; umount \$mnt_tmp; rmdir \$mnt_tmp")
                fi
                run_parallel "${s_args[@]}"
                success "All partitions formatted and subvolumes created."
                echo ""

                # ── Mount partitions ──
                echo "  Mounting root (@) to ${mnt} ..."
                while ! mount -o subvol=@ "$ROOT_PART" "$mnt"; do
                    warning "@ subvolume missing? Trying to create it ..."
                    mnt_tmp=$(mktemp -d)
                    mount "$ROOT_PART" "$mnt_tmp" 2>/dev/null && {
                        btrfs subvolume create "${mnt_tmp}/@" 2>/dev/null || true
                        umount "$mnt_tmp"
                    }
                    rmdir "$mnt_tmp" 2>/dev/null
                    retry_or_exit "Failed to mount root partition ($ROOT_PART) with subvol=@"
                done

                mkdir -p "${mnt}/boot" "${mnt}/home"

                echo "  Mounting boot to ${mnt}/boot ..."
                while ! mount "$BOOT_PART" "${mnt}/boot"; do
                    retry_or_exit "Failed to mount boot partition ($BOOT_PART)"
                done

                echo "  Probing home partition for @home subvolume ..."
                mnt_tmp=$(mktemp -d)
                if mount "$HOME_PART" "$mnt_tmp" 2>/dev/null; then
                    if btrfs subvolume list "$mnt_tmp" 2>/dev/null | grep -q '@home'; then
                        echo "  Mounting home (@home) to ${mnt}/home ..."
                        mount -o subvol=@home "$HOME_PART" "${mnt}/home"
                    else
                        warning "@home not found, mounting home directly"
                        mount "$HOME_PART" "${mnt}/home"
                    fi
                    umount "$mnt_tmp"
                    rmdir "$mnt_tmp"
                else
                    rmdir "$mnt_tmp" 2>/dev/null
                    warning "Could not probe home, mounting directly"
                    mount "$HOME_PART" "${mnt}/home" 2>/dev/null || true
                fi

                if [[ -n "$SWAP_PART" ]]; then
                    echo "  Enabling swap ..."
                    swapon "$SWAP_PART"
                fi
                success "All partitions mounted."
                echo ""

                # ── fstab reference (informational) ──
                echo "========================================================================================================================="
                echo " fstab Reference"
                echo "========================================================================================================================="
                echo ""
                echo "  After genfstab, these entries will be in ${mnt}/etc/fstab:"
                echo ""

                root_uuid=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || echo "<UUID>")
                home_uuid=$(blkid -s UUID -o value "$HOME_PART" 2>/dev/null || echo "<UUID>")
                boot_uuid=$(blkid -s UUID -o value "$BOOT_PART" 2>/dev/null || echo "<UUID>")
                swap_uuid=$(blkid -s UUID -o value "$SWAP_PART" 2>/dev/null || echo "<UUID>")

                echo "  # <file system>    <mount point>   <type>  <options>              <dump> <pass>"
                echo "  UUID=${root_uuid}  /               btrfs   rw,subvol=@            0      0"
                echo "  UUID=${home_uuid}  /home           btrfs   rw,subvol=@home        0      0"
                echo "  UUID=${boot_uuid}  /boot           vfat    rw,defaults            0      2"
                echo "  UUID=${swap_uuid}  swap            swap    defaults               0      0"
                echo ""
                echo "  Run: genfstab -U ${mnt} > ${mnt}/etc/fstab"
                echo ""

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            8) # Install Base System (pacstrap)
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 8
                section "Step 8: Install Base System"

                echo "  Installing base system (pacstrap)..."
                echo "  Packages: base base-devel linux-zen linux-lts linux-firmware"
                echo "           + dosfstools btrfs-progs"
                echo "           + networkmanager bluez bluez-utils cups cups-pk-helper pipewire"
                echo "           + ${bootloader} bootloader packages"
                echo ""

                # Write domestic mirrors (auto, no prompt)
                echo ">>> Writing domestic mirror list (12 mirrors, instant) ..."
                write_cn_mirrors
                success "12 domestic mirrors written."
                echo ""

                # Enable parallel downloads in live env
                echo ">>> Enabling parallel downloads (5) in /etc/pacman.conf ..."
                if grep -q '^ParallelDownloads' /etc/pacman.conf 2>/dev/null; then
                    sed -i 's/^ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
                else
                    sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf
                fi
                success "ParallelDownloads = 5"
                echo ""

                pkg_base="base base-devel linux-zen linux-zen-headers linux-lts linux-firmware dosfstools btrfs-progs"
                pkg_extra="networkmanager bluez bluez-utils cups cups-filters cups-pk-helper ghostscript pipewire pipewire-pulse wireplumber alsa-utils"
                pkg_boot=""
                if [[ "$bootloader" == "grub" ]]; then
                    pkg_boot="grub"
                    [[ "$firmware" == "uefi" ]] && pkg_boot="$pkg_boot efibootmgr"
                else
                    pkg_boot="efibootmgr"
                fi

                # Pre-flight disk space check
                echo ""
                echo ">>> Checking available disk space before pacstrap ..."
                echo "  ${mnt} (root @ subvolume):"
                df -h "${mnt}" | tail -1
                echo "  ${mnt}/boot (ESP):"
                df -h "${mnt}/boot" 2>/dev/null | tail -1 || echo "  (not mounted)"
                echo ""

                root_free_kb=$(df --output=avail "${mnt}" 2>/dev/null | tail -1)
                if [[ -n "$root_free_kb" ]] && (( root_free_kb < 10000000 )); then
                    error "Root partition has less than 10GB free (${root_free_kb} KB)."
                    error "pacstrap with dual kernels needs at least 10GB."
                    warning "Check partition sizes with: lsblk ${ROOT_PART}"
                    continue
                fi

                # Pacstrap with retry
                retry=0
                max_retries=3
                pacstrap_ok=0
                while (( retry < max_retries )); do
                    echo ">>> pacstrap -K ${mnt} (attempt $((retry+1))/${max_retries}) ..."
                    if pacstrap -K "$mnt" $pkg_base $pkg_extra $pkg_boot; then
                        pacstrap_ok=1
                        break
                    fi
                    retry=$((retry + 1))
                    if (( retry < max_retries )); then
                        warning "pacstrap failed (attempt $retry/${max_retries}), rewriting mirrors & retrying ..."
                        write_cn_mirrors
                        sleep 1
                    fi
                done

                # Fallback: reflector
                if [[ $pacstrap_ok -eq 0 ]] && command -v reflector &>/dev/null; then
                    echo ""
                    warning "Static mirrors exhausted, trying reflector to find more mirrors ..."
                    if timeout 30 reflector --verbose --country China --sort score --latest 30 --save /etc/pacman.d/mirrorlist 2>&1; then
                        success "Reflector found additional mirrors, retrying pacstrap ..."
                        if pacstrap -K "$mnt" $pkg_base $pkg_extra $pkg_boot; then
                            pacstrap_ok=1
                        fi
                    else
                        warning "Reflector failed or timed out."
                    fi
                elif [[ $pacstrap_ok -eq 0 ]]; then
                    warning "reflector not available, cannot try additional mirrors."
                fi

                if [[ $pacstrap_ok -eq 0 ]]; then
                    error "pacstrap failed after all attempts."
                    warning "You can retry manually: pacstrap -K ${mnt} ${pkg_base} ${pkg_extra} ${pkg_boot}"
                    continue
                fi
                success "Base system installed."

                # Copy mirror list to chroot
                echo ">>> Copying domestic mirror list to chroot ..."
                cp /etc/pacman.d/mirrorlist "${mnt}/etc/pacman.d/mirrorlist" 2>/dev/null || true
                success "Mirror list copied to target system."

                # Enable parallel downloads in chroot
                echo ">>> Enabling parallel downloads in target system ..."
                if grep -q '^ParallelDownloads' "${mnt}/etc/pacman.conf" 2>/dev/null; then
                    sed -i 's/^ParallelDownloads.*/ParallelDownloads = 5/' "${mnt}/etc/pacman.conf"
                else
                    sed -i '/^\[options\]/a ParallelDownloads = 5' "${mnt}/etc/pacman.conf"
                fi
                success "ParallelDownloads = 5 enabled in target system."

                # Generate fstab
                echo ">>> Generating fstab ..."
                root_uuid=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null)
                home_uuid=$(blkid -s UUID -o value "$HOME_PART" 2>/dev/null)
                boot_uuid=$(blkid -s UUID -o value "$BOOT_PART" 2>/dev/null)
                swap_uuid=$(blkid -s UUID -o value "$SWAP_PART" 2>/dev/null)

                cat > "${mnt}/etc/fstab" << FSTAB
# /etc/fstab: static file system information
# Generated by install.sh

UUID=${root_uuid}  /        btrfs  rw,noatime,subvol=@      0 0
UUID=${home_uuid}  /home    btrfs  rw,noatime,subvol=@home  0 0
UUID=${boot_uuid}  /boot    vfat   rw,noatime,fmask=0022,dmask=0022       0 2
UUID=${swap_uuid}  swap     swap   defaults                               0 0
FSTAB
                success "fstab generated (manual, subvol=@ / subvol=@home)."

                # Console keymap
                echo "KEYMAP=us" > "${mnt}/etc/vconsole.conf"
                success "vconsole.conf created (keymap=us)."

                # Timezone
                echo ">>> Setting timezone to Asia/Shanghai ..."
                arch-chroot "$mnt" ln -sf "/usr/share/zoneinfo/Asia/Shanghai" /etc/localtime
                arch-chroot "$mnt" hwclock --systohc
                success "Timezone set to Asia/Shanghai"

                # Locale
                echo ">>> Configuring locale en_US.UTF-8 ..."
                sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' "${mnt}/etc/locale.gen"
                arch-chroot "$mnt" locale-gen
                echo "LANG=en_US.UTF-8" > "${mnt}/etc/locale.conf"
                success "Locale set to en_US.UTF-8"

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            9) # Configure Hostname
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 9
                section "Step 9: Hostname"
                local hostname="archlinux"
                read -rp "$(echo -e "${CYAN}  Enter hostname (default archlinux): ${RESET}") " hostname_input
                [[ -n "$hostname_input" ]] && hostname="$hostname_input"
                echo "$hostname" > "${mnt}/etc/hostname"
                cat > "${mnt}/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF
                success "Hostname set to ${hostname}"

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            10) # Install Bootloader
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 10
                section "Step 10: Bootloader"
                info "Installing bootloader (${bootloader}) ..."

                root_partuuid=$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null)

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
                    success "systemd-boot installed (Zen default, LTS fallback)."
                else
                    if [[ "$firmware" == "uefi" ]]; then
                        arch-chroot "$mnt" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
                    else
                        disk_dev=$(echo "$disk" | sed 's/[0-9]*$//; s/p$//')
                        arch-chroot "$mnt" grub-install --target=i386-pc "$disk_dev"
                    fi
                    arch-chroot "$mnt" grub-mkconfig -o /boot/grub/grub.cfg
                    success "GRUB installed."
                fi

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            11) # Enable Services
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 11
                section "Step 11: Services"

                echo "  Enabling NetworkManager ..."
                arch-chroot "$mnt" systemctl enable NetworkManager
                success "NetworkManager enabled."

                echo "  Enabling bluetooth ..."
                arch-chroot "$mnt" systemctl enable bluetooth
                success "Bluetooth enabled."

                echo "  Enabling printing (cups) ..."
                arch-chroot "$mnt" systemctl enable cups
                success "Printing (cups) enabled."

                echo ""
                echo "  Enabling audio (PipeWire) ..."
                arch-chroot "$mnt" systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
                success "Audio (PipeWire) enabled."

                echo ""
                echo "  Configuring mkinitcpio for btrfs ..."
                arch-chroot "$mnt" sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
                arch-chroot "$mnt" sed -i 's/^#MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
                echo "  Regenerating initramfs for linux-zen and linux-lts in parallel ..."
                run_parallel \
                    "linux-zen initramfs"  "arch-chroot \"$mnt\" mkinitcpio -p linux-zen" \
                    "linux-lts initramfs"  "arch-chroot \"$mnt\" mkinitcpio -p linux-lts"
                success "Initramfs regenerated."

                echo "  Boot files:"
                ls -lh "${mnt}/boot/vmlinuz-"* "${mnt}/boot/initramfs-"*.img 2>/dev/null || warning "Missing boot files"

                echo ""
                echo "  Enabling sudo for wheel group ..."
                arch-chroot "$mnt" sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
                success "sudo enabled for wheel group."

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            12) # Set Root Password
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 12
                section "Step 12: Set Root Password"
                read -rp "$(echo -e "${YELLOW}  Set root password now? [Y/n]: ${RESET}") " ans
                case "$ans" in
                    n|N) success "Skipped."; COMPLETED[$step]=1; continue ;;
                    *) ;;
                esac

                while true; do
                    read -rsp "$(echo -e "${CYAN}  Enter root password: ${RESET}") " rp1; echo ""
                    read -rsp "$(echo -e "${CYAN}  Confirm root password: ${RESET}") " rp2; echo ""
                    if [[ "$rp1" != "$rp2" ]]; then
                        warning "Passwords do not match."
                    elif [[ -z "$rp1" ]]; then
                        warning "Password cannot be empty."
                    else
                        echo "root:$rp1" | arch-chroot "$mnt" chpasswd
                        success "Root password set."
                        break
                    fi
                done

                COMPLETED[$step]=1
                ;;

            # ─────────────────────────────────────
            13) # Create User + Finalize
            # ─────────────────────────────────────
                clear
                print_logo
                show_progress 13
                section "Step 13: Create User"
                read -rp "$(echo -e "${YELLOW}  Create a new user? [Y/n]: ${RESET}") " ans
                case "$ans" in
                    n|N) success "Skipped user creation." ;;
                    *)
                        read -rp "$(echo -e "${CYAN}  Enter username: ${RESET}") " username
                        if [[ -n "$username" ]]; then
                            while true; do
                                read -rsp "$(echo -e "${CYAN}  Enter password: ${RESET}") " up1; echo ""
                                read -rsp "$(echo -e "${CYAN}  Confirm password: ${RESET}") " up2; echo ""
                                if [[ "$up1" != "$up2" ]]; then
                                    warning "Passwords do not match."
                                elif [[ -z "$up1" ]]; then
                                    warning "Password cannot be empty."
                                else
                                    arch-chroot "$mnt" useradd -m -G wheel -s /bin/bash "$username"
                                    echo "$username:$up1" | arch-chroot "$mnt" chpasswd
                                    success "User '$username' created (wheel group)."
                                    success "Run 'visudo' inside the system to enable sudo."
                                    break
                                fi
                            done
                        fi
                        ;;
                esac

                # ── Finalize ──
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
                    *) success "You can reboot later with: reboot" ;;
                esac
                COMPLETED[$step]=1; break   # exit while loop
                ;;
        esac
    done
}

# ─── Entry ────────────────────────────────────
main "$@"
