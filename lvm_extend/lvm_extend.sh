#!/usr/bin/env bash
# =============================================================================
#  lvm_extend.sh — LVM Volume Extension Utility
#  Captures storage/LVM info, guides extension, produces a timestamped report
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[1;34m';   BOLD='\033[1m'; RESET='\033[0m'
MAGENTA='\033[0;35m'; WHITE='\033[1;37m'

# ── Report file setup ─────────────────────────────────────────────────────────
HOSTNAME_VAL=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
REPORT_DIR="/var/log/lvm_reports"
REPORT_FILE="${REPORT_DIR}/lvm_report_${HOSTNAME_VAL}_${TIMESTAMP}.txt"
mkdir -p "$REPORT_DIR"
> "$REPORT_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo -e "$1" | tee -a "$REPORT_FILE"; }
lograw() { echo    "$1" | tee -a "$REPORT_FILE"; }

section() {
    local line="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log ""
    log "${CYAN}${line}${RESET}"
    log "${BOLD}${WHITE}  $1${RESET}"
    log "${CYAN}${line}${RESET}"
}

info()    { log "  ${GREEN}[INFO]${RESET}  $1"; }
warn()    { log "  ${YELLOW}[WARN]${RESET}  $1"; }
error()   { log "  ${RED}[ERROR]${RESET} $1"; }
success() { log "  ${GREEN}[OK]${RESET}    $1"; }
step()    { log "  ${BLUE}[STEP]${RESET}  $1"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} Run as root: sudo $0"
    exit 1
fi

# ── Required tools check ──────────────────────────────────────────────────────
for tool in lsblk pvs vgs lvs pvdisplay vgdisplay lvdisplay df blkid findmnt; do
    command -v "$tool" &>/dev/null || echo -e "${YELLOW}[WARN]${RESET} Missing tool: $tool"
done

# =============================================================================
#  REPORT HEADER
# =============================================================================
clear
OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
DATETIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

log "╔══════════════════════════════════════════════════════════════════════════════╗"
log "║                                                                              ║"
log "║    LVM Volume Extension Utility — System Storage Report                     ║"
log "║                                                                              ║"
log "║    Hostname  : ${HOSTNAME_VAL}$(printf '%*s' $((58 - ${#HOSTNAME_VAL})) '')║"
log "║    OS        : ${OS_NAME}$(printf '%*s' $((58 - ${#OS_NAME})) '')║"
log "║    Kernel    : ${KERNEL}$(printf '%*s' $((58 - ${#KERNEL})) '')║"
log "║    Date/Time : ${DATETIME}$(printf '%*s' $((58 - ${#DATETIME})) '')║"
log "║    Report    : ${REPORT_FILE}$(printf '%*s' $((58 - ${#REPORT_FILE})) '')║"
log "║                                                                              ║"
log "╚══════════════════════════════════════════════════════════════════════════════╝"

# =============================================================================
#  SECTION 1 — FILESYSTEM USAGE
# =============================================================================
section "1. FILESYSTEM & MOUNT POINTS"
log ""
log "  ${BOLD}$(printf '%-38s %6s %6s %6s %5s  %s' 'Filesystem' 'Size' 'Used' 'Avail' 'Use%' 'Mounted on')${RESET}"
log "  $(printf '%.0s─' {1..75})"
df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2 | \
while IFS= read -r line; do
    pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    if [[ "$pct" =~ ^[0-9]+$ && $pct -ge 90 ]]; then
        echo -e "  ${RED}${line}${RESET}" | tee -a "$REPORT_FILE"
    elif [[ "$pct" =~ ^[0-9]+$ && $pct -ge 70 ]]; then
        echo -e "  ${YELLOW}${line}${RESET}" | tee -a "$REPORT_FILE"
    else
        echo "  ${line}" | tee -a "$REPORT_FILE"
    fi
done
log ""
info "Colour: ${RED}RED${RESET}=>=90% used   ${YELLOW}YELLOW${RESET}=>=70% used"

# =============================================================================
#  SECTION 2 — BLOCK DEVICES
# =============================================================================
section "2. BLOCK DEVICES"
log ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,ROTA,LABEL 2>/dev/null | \
while IFS= read -r line; do log "  $line"; done

# =============================================================================
#  SECTION 3 — PHYSICAL VOLUMES
# =============================================================================
section "3. LVM — PHYSICAL VOLUMES"
log ""
if pvs --noheadings 2>/dev/null | grep -q .; then
    log "  ${BOLD}$(printf '%-22s %-16s %-8s %-10s %-10s' 'PV Name' 'VG Name' 'Format' 'PV Size' 'PV Free')${RESET}"
    log "  $(printf '%.0s─' {1..66})"
    pvs --noheadings --units g --separator '|' \
        -o pv_name,vg_name,pv_fmt,pv_size,pv_free 2>/dev/null | \
    while IFS='|' read -r pv vg fmt sz fr; do
        printf "  %-22s %-16s %-8s %-10s %-10s\n" \
            "${pv// /}" "${vg// /}" "${fmt// /}" "${sz// /}" "${fr// /}" \
            | tee -a "$REPORT_FILE"
    done
    log ""
    log "  ${BOLD}── Detailed PV Info ──${RESET}"
    pvdisplay 2>/dev/null | grep -E "PV Name|VG Name|PV Size|Allocatable|PE Size|Total PE|Free PE|Allocated PE" | \
    while IFS= read -r l; do log "    $l"; done
else
    warn "No Physical Volumes found."
fi

# =============================================================================
#  SECTION 4 — VOLUME GROUPS
# =============================================================================
section "4. LVM — VOLUME GROUPS"
log ""
if vgs --noheadings 2>/dev/null | grep -q .; then
    log "  ${BOLD}$(printf '%-20s %-6s %-6s %-12s %-12s' 'VG Name' '#PVs' '#LVs' 'VG Size' 'VG Free')${RESET}"
    log "  $(printf '%.0s─' {1..56})"
    vgs --noheadings --units g --separator '|' \
        -o vg_name,pv_count,lv_count,vg_size,vg_free 2>/dev/null | \
    while IFS='|' read -r vg pvc lvc vsz vfr; do
        fv=$(echo "${vfr// /}" | tr -d 'gG<')
        if awk "BEGIN{exit !($fv < 1)}" 2>/dev/null; then
            printf "  ${YELLOW}%-20s %-6s %-6s %-12s %-12s${RESET}\n" \
                "${vg// /}" "${pvc// /}" "${lvc// /}" "${vsz// /}" "${vfr// /}" \
                | tee -a "$REPORT_FILE"
        else
            printf "  %-20s %-6s %-6s %-12s %-12s\n" \
                "${vg// /}" "${pvc// /}" "${lvc// /}" "${vsz// /}" "${vfr// /}" \
                | tee -a "$REPORT_FILE"
        fi
    done
    log ""
    log "  ${BOLD}── Detailed VG Info ──${RESET}"
    vgdisplay 2>/dev/null | grep -E "VG Name|Format|VG Size|PE Size|Total PE|Alloc PE|Free PE" | \
    while IFS= read -r l; do log "    $l"; done
else
    warn "No Volume Groups found."
fi

# =============================================================================
#  SECTION 5 — LOGICAL VOLUMES
# =============================================================================
section "5. LVM — LOGICAL VOLUMES"
log ""
if lvs --noheadings 2>/dev/null | grep -q .; then
    log "  ${BOLD}$(printf '%-32s %-18s %-10s %-8s' 'LV Path' 'VG Name' 'LV Size' 'Type')${RESET}"
    log "  $(printf '%.0s─' {1..68})"
    lvs --noheadings --units g --separator '|' \
        -o lv_path,vg_name,lv_size,segtype 2>/dev/null | \
    while IFS='|' read -r lp vg ls st; do
        printf "  %-32s %-18s %-10s %-8s\n" \
            "${lp// /}" "${vg// /}" "${ls// /}" "${st// /}" \
            | tee -a "$REPORT_FILE"
    done
    log ""
    log "  ${BOLD}── Detailed LV Info ──${RESET}"
    lvdisplay 2>/dev/null | grep -E "LV Path|LV Name|VG Name|LV Size|LV UUID" | \
    while IFS= read -r l; do log "    $l"; done
else
    warn "No Logical Volumes found."
fi

# =============================================================================
#  SECTION 6 — FSTAB
# =============================================================================
section "6. /etc/fstab — PERSISTENT MOUNTS"
log ""
while IFS= read -r line; do log "  $line"; done < /etc/fstab

# =============================================================================
#  SECTION 7 — INTERACTIVE EXTENSION
# =============================================================================
section "7. INTERACTIVE — EXTEND A LOGICAL VOLUME"
log ""
log "  ${BOLD}Review the storage info above before proceeding.${RESET}"
log "  ${YELLOW}All operations are logged to: ${REPORT_FILE}${RESET}"
log ""

echo -ne "  ${BOLD}Extend a Logical Volume now? [y/N]: ${RESET}"
read -r PROCEED
if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
    info "Extension skipped by user."
    section "REPORT COMPLETE"
    log "  Report saved to: ${GREEN}${REPORT_FILE}${RESET}"
    echo -e "\n  ${GREEN}Report:${RESET} ${BOLD}${REPORT_FILE}${RESET}\n"
    exit 0
fi
log ""
log "  User confirmed: proceed with extension"

# ── 7a: Source of new space ───────────────────────────────────────────────────
log ""
log "  ${BOLD}Select source of additional disk space:${RESET}"
log "  ${CYAN}[1]${RESET} New physical disk          (e.g. /dev/sdb)"
log "  ${CYAN}[2]${RESET} New partition on disk      (e.g. /dev/sda3)"
log "  ${CYAN}[3]${RESET} VM/cloud disk was resized  (growpart + pvresize)"
log "  ${CYAN}[4]${RESET} VG already has free space  (skip to LV extend)"
echo ""
echo -ne "  ${BOLD}Choose [1-4]: ${RESET}"
read -r SRC
log "  Selected source type: ${SRC}"
NEW_PV=""

case "$SRC" in
  1)
    log ""
    log "  ${BOLD}Detected disks:${RESET}"
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | tee -a "$REPORT_FILE"
    echo ""
    echo -ne "  ${BOLD}Enter new disk path (e.g. /dev/sdb): ${RESET}"
    read -r NEW_DISK
    log "  Input: ${NEW_DISK}"
    [[ ! -b "$NEW_DISK" ]] && { error "Device ${NEW_DISK} not found."; exit 1; }
    step "Checking for existing signatures on ${NEW_DISK} ..."
    EXISTING_SIG=$(wipefs "$NEW_DISK" 2>/dev/null)
    if [[ -n "$EXISTING_SIG" ]]; then
        warn "Existing signatures detected on ${NEW_DISK}:"
        echo "$EXISTING_SIG" | tee -a "$REPORT_FILE"
        log ""
        log "  ${BOLD}── Current PV/VG metadata on ${NEW_DISK} ──${RESET}"
        pvdisplay "$NEW_DISK" 2>/dev/null | tee -a "$REPORT_FILE" || \
            log "  (no readable pvdisplay metadata)"
        log ""
        echo -ne "  ${BOLD}${YELLOW}Wipe ALL signatures and reinitialise ${NEW_DISK}? [y/N]: ${RESET}"
        read -r WIPE_CONFIRM
        if [[ "$WIPE_CONFIRM" =~ ^[Yy]$ ]]; then
            step "wipefs -a ${NEW_DISK}"
            wipefs -a "$NEW_DISK" 2>&1 | tee -a "$REPORT_FILE"
            success "All signatures wiped from ${NEW_DISK}"
        else
            error "Wipe declined by user. Cannot create PV on a disk with existing metadata. Aborting."
            exit 1
        fi
    fi
    step "pvcreate ${NEW_DISK}"
    if ! pvcreate "$NEW_DISK" 2>&1 | tee -a "$REPORT_FILE"; then
        warn "pvcreate failed — retrying with force flag (-ff) ..."
        echo -ne "  ${BOLD}${YELLOW}Force initialise ${NEW_DISK} with -ff? [y/N]: ${RESET}"
        read -r FORCE_CONFIRM
        if [[ "$FORCE_CONFIRM" =~ ^[Yy]$ ]]; then
            step "pvcreate -ff ${NEW_DISK}"
            echo "y" | pvcreate -ff "$NEW_DISK" 2>&1 | tee -a "$REPORT_FILE"
            success "PV force-created: ${NEW_DISK}"
        else
            error "Force init declined. Aborting."
            exit 1
        fi
    else
        success "PV created: ${NEW_DISK}"
    fi
    NEW_PV="$NEW_DISK"
    ;;
  2)
    log ""
    log "  ${BOLD}Detected partitions:${RESET}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE 2>/dev/null | tee -a "$REPORT_FILE"
    echo ""
    echo -ne "  ${BOLD}Enter partition path (e.g. /dev/sda3): ${RESET}"
    read -r NEW_PART
    log "  Input: ${NEW_PART}"
    [[ ! -b "$NEW_PART" ]] && { error "Partition ${NEW_PART} not found."; exit 1; }
    step "Checking for existing signatures on ${NEW_PART} ..."
    EXISTING_SIG=$(wipefs "$NEW_PART" 2>/dev/null)
    if [[ -n "$EXISTING_SIG" ]]; then
        warn "Existing signatures detected on ${NEW_PART}:"
        echo "$EXISTING_SIG" | tee -a "$REPORT_FILE"
        log ""
        log "  ${BOLD}── Current PV/VG metadata on ${NEW_PART} ──${RESET}"
        pvdisplay "$NEW_PART" 2>/dev/null | tee -a "$REPORT_FILE" || \
            log "  (no readable pvdisplay metadata)"
        log ""
        echo -ne "  ${BOLD}${YELLOW}Wipe ALL signatures and reinitialise ${NEW_PART}? [y/N]: ${RESET}"
        read -r WIPE_CONFIRM
        if [[ "$WIPE_CONFIRM" =~ ^[Yy]$ ]]; then
            step "wipefs -a ${NEW_PART}"
            wipefs -a "$NEW_PART" 2>&1 | tee -a "$REPORT_FILE"
            success "All signatures wiped from ${NEW_PART}"
        else
            error "Wipe declined by user. Cannot create PV on a partition with existing metadata. Aborting."
            exit 1
        fi
    fi
    step "pvcreate ${NEW_PART}"
    if ! pvcreate "$NEW_PART" 2>&1 | tee -a "$REPORT_FILE"; then
        warn "pvcreate failed — retrying with force flag (-ff) ..."
        echo -ne "  ${BOLD}${YELLOW}Force initialise ${NEW_PART} with -ff? [y/N]: ${RESET}"
        read -r FORCE_CONFIRM
        if [[ "$FORCE_CONFIRM" =~ ^[Yy]$ ]]; then
            step "pvcreate -ff ${NEW_PART}"
            echo "y" | pvcreate -ff "$NEW_PART" 2>&1 | tee -a "$REPORT_FILE"
            success "PV force-created: ${NEW_PART}"
        else
            error "Force init declined. Aborting."
            exit 1
        fi
    else
        success "PV created: ${NEW_PART}"
    fi
    NEW_PV="$NEW_PART"
    ;;
  3)
    log ""
    lsblk -d -o NAME,SIZE 2>/dev/null | tee -a "$REPORT_FILE"
    echo ""
    echo -ne "  ${BOLD}Enter disk (e.g. /dev/sda): ${RESET}"
    read -r GP_DISK
    echo -ne "  ${BOLD}Enter partition number (e.g. 3): ${RESET}"
    read -r GP_NUM
    log "  Input: growpart ${GP_DISK} ${GP_NUM}"
    if ! command -v growpart &>/dev/null; then
        warn "growpart not found — installing cloud-guest-utils ..."
        apt-get install -y cloud-guest-utils 2>&1 | tail -3 | tee -a "$REPORT_FILE"
    fi
    step "growpart ${GP_DISK} ${GP_NUM}"
    growpart "$GP_DISK" "$GP_NUM" 2>&1 | tee -a "$REPORT_FILE"
    step "pvresize ${GP_DISK}${GP_NUM}"
    pvresize "${GP_DISK}${GP_NUM}" 2>&1 | tee -a "$REPORT_FILE"
    success "Disk resized and PV updated"
    NEW_PV=""
    SRC=4
    ;;
  4)
    info "Using existing VG free space."
    NEW_PV=""
    ;;
  *)
    error "Invalid option."
    exit 1
    ;;
esac

# ── 7b: Select Volume Group ───────────────────────────────────────────────────
log ""
log "  ${BOLD}Volume Groups:${RESET}"
vgs 2>/dev/null | tee -a "$REPORT_FILE"
echo ""
echo -ne "  ${BOLD}Enter VG name (e.g. ubuntu-vg): ${RESET}"
read -r VG_NAME
log "  Selected VG: ${VG_NAME}"
vgs "$VG_NAME" &>/dev/null || { error "VG '${VG_NAME}' not found."; exit 1; }

# ── Missing PV check & remediation ───────────────────────────────────────────
log ""
step "Checking VG '${VG_NAME}' for missing Physical Volumes ..."

MISSING_PV=$(vgs --noheadings -o vg_missing_pv_count "$VG_NAME" 2>/dev/null | tr -d ' ' || echo "0")

if [[ "$MISSING_PV" =~ ^[0-9]+$ && "$MISSING_PV" -gt 0 ]]; then
    log ""
    warn "VG '${VG_NAME}' has ${MISSING_PV} missing PV(s) — operations are blocked until resolved."
    log ""
    log "  ${BOLD}── Missing PV Details ──${RESET}"
    pvs --all 2>/dev/null | tee -a "$REPORT_FILE"
    log ""
    log "  ${BOLD}── VG Full Status ──${RESET}"
    vgdisplay "$VG_NAME" 2>/dev/null | tee -a "$REPORT_FILE"
    log ""
    log "  ${BOLD}How do you want to resolve the missing PV?${RESET}"
    log "  ${CYAN}[1]${RESET} Remove missing PV record from VG  ${YELLOW}(disk gone for good — safe if no data on it)${RESET}"
    log "  ${CYAN}[2]${RESET} Restore missing PV back into VG   ${YELLOW}(disk still exists but VG lost track of it)${RESET}"
    log "  ${CYAN}[3]${RESET} Abort — I will fix this manually"
    echo ""
    echo -ne "  ${BOLD}Choose [1-3]: ${RESET}"
    read -r MISSING_FIX
    log "  Selected missing PV fix: ${MISSING_FIX}"

    case "$MISSING_FIX" in
      1)
        log ""
        warn "This will permanently remove the missing PV record from VG '${VG_NAME}'."
        warn "Only proceed if the disk is physically gone and had NO active LV data on it."
        echo -ne "  ${BOLD}${RED}Confirm removal of missing PV record? [y/N]: ${RESET}"
        read -r CONFIRM_REDUCE
        if [[ "$CONFIRM_REDUCE" =~ ^[Yy]$ ]]; then
            step "vgreduce --removemissing --force ${VG_NAME}"
            vgreduce --removemissing --force "$VG_NAME" 2>&1 | tee -a "$REPORT_FILE"
            success "Missing PV record removed from VG '${VG_NAME}'"
            log ""
            log "  ${BOLD}── Updated VG Status ──${RESET}"
            vgs "$VG_NAME" 2>/dev/null | tee -a "$REPORT_FILE"
        else
            error "Aborted by user."
            exit 1
        fi
        ;;
      2)
        log ""
        log "  ${BOLD}Available block devices:${RESET}"
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | tee -a "$REPORT_FILE"
        echo ""
        echo -ne "  ${BOLD}Enter device path of the missing PV (e.g. /dev/sdc): ${RESET}"
        read -r RESTORE_DEV
        log "  Input: ${RESTORE_DEV}"
        [[ ! -b "$RESTORE_DEV" ]] && { error "Device ${RESTORE_DEV} not found."; exit 1; }
        step "vgextend --restoremissing ${VG_NAME} ${RESTORE_DEV}"
        vgextend --restoremissing "$VG_NAME" "$RESTORE_DEV" 2>&1 | tee -a "$REPORT_FILE"
        success "Missing PV restored into VG '${VG_NAME}'"
        log ""
        log "  ${BOLD}── Updated VG Status ──${RESET}"
        vgs "$VG_NAME" 2>/dev/null | tee -a "$REPORT_FILE"
        ;;
      3)
        warn "Aborted by user. Fix the missing PV manually then re-run the script."
        warn "Hint: sudo vgreduce --removemissing --force ${VG_NAME}"
        warn "  or: sudo vgextend --restoremissing ${VG_NAME} /dev/sdX"
        log ""
        log "  Report saved to: ${GREEN}${REPORT_FILE}${RESET}"
        exit 0
        ;;
      *)
        error "Invalid option. Aborting."
        exit 1
        ;;
    esac

    # Final health check — confirm VG is clean before proceeding
    STILL_MISSING=$(vgs --noheadings -o vg_missing_pv_count "$VG_NAME" 2>/dev/null | tr -d ' ' || echo "0")
    if [[ "$STILL_MISSING" =~ ^[0-9]+$ && "$STILL_MISSING" -gt 0 ]]; then
        error "VG '${VG_NAME}' still has missing PVs after remediation. Cannot proceed safely."
        error "Run: sudo vgdisplay ${VG_NAME}  to investigate further."
        exit 1
    fi
    success "VG '${VG_NAME}' is now healthy — no missing PVs."
else
    success "VG '${VG_NAME}' is healthy — no missing PVs detected."
fi

# ── vgextend if needed ────────────────────────────────────────────────────────
if [[ -n "$NEW_PV" ]]; then
    step "vgextend ${VG_NAME} ${NEW_PV}"
    vgextend "$VG_NAME" "$NEW_PV" 2>&1 | tee -a "$REPORT_FILE"
    success "VG extended"
fi

# ── 7c: Select Logical Volume ─────────────────────────────────────────────────
log ""
log "  ${BOLD}Logical Volumes in '${VG_NAME}':${RESET}"
lvs "$VG_NAME" 2>/dev/null | tee -a "$REPORT_FILE"
echo ""
echo -ne "  ${BOLD}Enter LV path (e.g. /dev/ubuntu-vg/ubuntu-lv): ${RESET}"
read -r LV_PATH
log "  Selected LV: ${LV_PATH}"
lvs "$LV_PATH" &>/dev/null || { error "LV '${LV_PATH}' not found."; exit 1; }

# ── 7d: Size to add ───────────────────────────────────────────────────────────
log ""
log "  ${BOLD}How much space to add?${RESET}"
log "  ${CYAN}[1]${RESET} Use ALL available free space in VG"
log "  ${CYAN}[2]${RESET} Specify exact amount (e.g. 50G)"
echo ""
echo -ne "  ${BOLD}Choose [1/2]: ${RESET}"
read -r SZ_OPT

if [[ "$SZ_OPT" == "1" ]]; then
    step "lvextend -l +100%FREE ${LV_PATH}"
    LVEXT_OUT=$(lvextend -l +100%FREE "$LV_PATH" 2>&1)
    echo "$LVEXT_OUT" | tee -a "$REPORT_FILE"
    if echo "$LVEXT_OUT" | grep -qi "missing\|Cannot process\|PVs are missing"; then
        error "lvextend failed — VG has missing PVs. Re-run script and fix VG health check."
        exit 1
    elif echo "$LVEXT_OUT" | grep -qi "successfully resized\|already at maximum\|matches the existing"; then
        success "LV extended"
    else
        error "lvextend failed with unexpected error. Check output above."
        exit 1
    fi
elif [[ "$SZ_OPT" == "2" ]]; then
    echo -ne "  ${BOLD}Enter size (e.g. 50G): ${RESET}"
    read -r ADD_SZ
    log "  Size input: ${ADD_SZ}"
    step "lvextend -L +${ADD_SZ} ${LV_PATH}"
    LVEXT_OUT=$(lvextend -L "+${ADD_SZ}" "$LV_PATH" 2>&1)
    echo "$LVEXT_OUT" | tee -a "$REPORT_FILE"
    if echo "$LVEXT_OUT" | grep -qi "missing\|Cannot process\|PVs are missing"; then
        error "lvextend failed — VG has missing PVs. Re-run script and fix VG health check."
        exit 1
    elif echo "$LVEXT_OUT" | grep -qi "successfully resized"; then
        success "LV extended"
    else
        error "lvextend failed. Insufficient space or invalid size. Check output above."
        exit 1
    fi
else
    error "Invalid option."
    exit 1
fi
success "LV extended"

# ── 7e: Resize filesystem ─────────────────────────────────────────────────────
log ""
FS_TYPE=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null || echo "unknown")
info "Filesystem detected: ${FS_TYPE}"

case "$FS_TYPE" in
  ext2|ext3|ext4)
    step "resize2fs ${LV_PATH}"
    resize2fs "$LV_PATH" 2>&1 | tee -a "$REPORT_FILE"
    success "Filesystem resized (resize2fs)"
    ;;
  xfs)
    MP=$(findmnt -n -o TARGET "$LV_PATH" 2>/dev/null || echo "/")
    step "xfs_growfs ${MP}"
    xfs_growfs "$MP" 2>&1 | tee -a "$REPORT_FILE"
    success "Filesystem resized (xfs_growfs)"
    ;;
  *)
    warn "Unknown filesystem '${FS_TYPE}'. Resize manually:"
    warn "  ext4: resize2fs ${LV_PATH}"
    warn "  xfs:  xfs_growfs <mountpoint>"
    ;;
esac

# =============================================================================
#  SECTION 8 — POST-EXTENSION STATE
# =============================================================================
section "8. POST-EXTENSION STORAGE STATE"
log ""
log "  ${BOLD}── Updated df -h ──${RESET}"
df -h 2>/dev/null | while IFS= read -r l; do log "  $l"; done
log ""
log "  ${BOLD}── Updated PVs ──${RESET}"
pvs 2>/dev/null | while IFS= read -r l; do log "  $l"; done
log ""
log "  ${BOLD}── Updated VGs ──${RESET}"
vgs 2>/dev/null | while IFS= read -r l; do log "  $l"; done
log ""
log "  ${BOLD}── Updated LVs ──${RESET}"
lvs 2>/dev/null | while IFS= read -r l; do log "  $l"; done
log ""
log "  ${BOLD}── Updated lsblk ──${RESET}"
lsblk 2>/dev/null | while IFS= read -r l; do log "  $l"; done

# =============================================================================
#  FOOTER
# =============================================================================
section "REPORT SUMMARY"
log ""
log "  ${BOLD}Hostname      :${RESET} ${HOSTNAME_VAL}"
log "  ${BOLD}OS            :${RESET} ${OS_NAME}"
log "  ${BOLD}Kernel        :${RESET} ${KERNEL}"
log "  ${BOLD}Completed at  :${RESET} $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "  ${BOLD}Report saved  :${RESET} ${GREEN}${REPORT_FILE}${RESET}"
log ""
log "${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${RESET}"
log "${GREEN}║            LVM Extension Completed Successfully                             ║${RESET}"
log "${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${RESET}"
log ""
echo ""
echo -e "  ${GREEN}${BOLD}Done!${RESET}  Report: ${BOLD}${REPORT_FILE}${RESET}"
echo ""
