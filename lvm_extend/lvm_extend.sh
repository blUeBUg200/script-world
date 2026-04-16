#!/usr/bin/env bash
# ============================================================
#  lvm_extend.sh — LVM Volume Extension Utility
#  Audits storage layout, guides LVM extension interactively,
#  resizes the filesystem, and produces a timestamped HTML report.
#
#  Usage:  sudo ./lvm_extend.sh
#  Notes:  Must be run as root.
#          Reports saved to ./lvm_reports/
# ============================================================

set -euo pipefail

# ── Colours (terminal) ──────────────────────────────────────
RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[1;34m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Defaults ────────────────────────────────────────────────
REPORT_DIR="$(pwd)/lvm_reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
DATE_HUMAN=$(date '+%A, %d %B %Y — %H:%M:%S %Z')
HOST_NAME=$(hostname 2>/dev/null || echo "unknown")
REPORT_FILE="${REPORT_DIR}/lvm_report_${HOST_NAME}_${TIMESTAMP}.html"

# ── Runtime state (populated during interactive section) ────
VG_NAME=""
LV_PATH=""
NEW_PV=""
ADD_SZ=""
SZ_OPT=""
FS_TYPE=""
EXTENSION_DONE=false
EXTENSION_SKIPPED=false

# Capture all interactive steps as HTML rows for the report
HTML_STEPS=""

# ── Root check ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${RESET} This script must be run as root: sudo $0"
  exit 1
fi

# ── Required tools check ────────────────────────────────────
MISSING_TOOLS=()
for tool in lsblk pvs vgs lvs pvdisplay vgdisplay lvdisplay lvextend vgextend \
            vgreduce df blkid findmnt wipefs; do
  command -v "$tool" &>/dev/null || MISSING_TOOLS+=("$tool")
done

# ── OS info ─────────────────────────────────────────────────
OS_NAME="unknown"
OS_VERSION="unknown"
OS_ID="unknown"
OS_CODENAME="n/a"
OS_KERNEL=$(uname -r 2>/dev/null || echo "unknown")
OS_ARCH=$(uname -m 2>/dev/null || echo "unknown")

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-unknown}"
  OS_VERSION="${VERSION:-${VERSION_ID:-unknown}}"
  OS_ID="${ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-n/a}}"
elif [[ -f /etc/redhat-release ]]; then
  OS_NAME=$(cat /etc/redhat-release)
  OS_ID="rhel"
fi

# ── Terminal helper functions ────────────────────────────────
sep()     { echo -e "  ─────────────────────────────────────────────────────"; }
info()    { echo -e "  ${GREEN}[INFO]${RESET}  $1"; }
warn()    { echo -e "  ${ORANGE}[WARN]${RESET}  $1"; }
err()     { echo -e "  ${RED}[ERROR]${RESET} $1"; }
ok()      { echo -e "  ${GREEN}[ OK ]${RESET}  $1"; }
step()    { echo -e "  ${BLUE}[STEP]${RESET}  $1"; }
osline()  { echo -e "  ${CYAN}[ OS ]${RESET}  $1"; }

section() {
  echo ""
  echo -e "  ${BOLD}${CYAN}$1${RESET}"
  sep
}

# ── HTML accumulator helpers ─────────────────────────────────
badge() {
  local type="$1" text="$2"
  echo "<span class=\"badge ${type}\">${text}</span>"
}

# Append a labelled row to HTML_STEPS
html_step() {
  local label="$1" detail="$2" badge_html="$3"
  HTML_STEPS+="
    <div class=\"tool-row\">
      <div class=\"tool-name\">${label}</div>
      <div class=\"tool-detail\">${detail}</div>
      <div>${badge_html}</div>
    </div>"
}

# Append a code block to HTML_STEPS (for command output)
html_code() {
  local title="$1" content="$2"
  local escaped
  escaped=$(printf '%s' "$content" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  HTML_STEPS+="
    <div class=\"code-block\">
      <div class=\"code-title\">${title}</div>
      <pre>${escaped}</pre>
    </div>"
}

# ============================================================
#  TERMINAL — HEADER
# ============================================================
clear
echo ""
echo -e "  ${BOLD}LVM Volume Extension Utility${RESET}"
echo -e "  Date: ${DATE_HUMAN}"
sep
osline "OS              ${OS_NAME}"
osline "Version         ${OS_VERSION} (${OS_CODENAME})"
osline "Kernel          ${OS_KERNEL}"
osline "Architecture    ${OS_ARCH}"
osline "Hostname        ${HOST_NAME}"

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  echo ""
  warn "Missing tools: ${MISSING_TOOLS[*]}"
  warn "Install lvm2 package to ensure all tools are available."
fi

# ============================================================
#  SECTION 1 — FILESYSTEM USAGE
# ============================================================
section "1. Filesystem & Mount Points"
echo ""
printf "  %-38s %6s %6s %6s %5s  %s\n" 'Filesystem' 'Size' 'Used' 'Avail' 'Use%' 'Mounted on'
sep

# Collect filesystem data for HTML
FS_HTML_ROWS=""
df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2 | \
while IFS= read -r line; do
  pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
  if [[ "$pct" =~ ^[0-9]+$ && $pct -ge 90 ]]; then
    echo -e "  ${RED}${line}${RESET}"
    fs_cls="fail"
  elif [[ "$pct" =~ ^[0-9]+$ && $pct -ge 70 ]]; then
    echo -e "  ${ORANGE}${line}${RESET}"
    fs_cls="warn"
  else
    echo "  ${line}"
    fs_cls="ok"
  fi
done
echo ""
info "Colour: ${RED}>=90% used${RESET}   ${ORANGE}>=70% used${RESET}"

# Capture filesystem table for HTML (plain, no colours)
FS_TABLE=$(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2)

# ============================================================
#  SECTION 2 — BLOCK DEVICES
# ============================================================
section "2. Block Devices"
echo ""
LSBLK_OUT=$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,ROTA,LABEL 2>/dev/null || echo "lsblk not available")
echo "$LSBLK_OUT" | while IFS= read -r line; do echo "  $line"; done

# ============================================================
#  SECTION 3 — PHYSICAL VOLUMES
# ============================================================
section "3. LVM — Physical Volumes"
echo ""
if pvs --noheadings 2>/dev/null | grep -q .; then
  printf "  %-22s %-16s %-8s %-10s %-10s\n" 'PV Name' 'VG Name' 'Format' 'PV Size' 'PV Free'
  sep
  PV_TABLE=$(pvs --noheadings --units g --separator '|' \
    -o pv_name,vg_name,pv_fmt,pv_size,pv_free 2>/dev/null)
  echo "$PV_TABLE" | while IFS='|' read -r pv vg fmt sz fr; do
    printf "  %-22s %-16s %-8s %-10s %-10s\n" \
      "${pv// /}" "${vg// /}" "${fmt// /}" "${sz// /}" "${fr// /}"
  done
  echo ""
  info "Detailed PV info:"
  PV_DETAIL=$(pvdisplay 2>/dev/null | grep -E "PV Name|VG Name|PV Size|Allocatable|PE Size|Total PE|Free PE|Allocated PE" || true)
  echo "$PV_DETAIL" | while IFS= read -r l; do echo "    $l"; done
else
  warn "No Physical Volumes found."
  PV_TABLE=""
  PV_DETAIL=""
fi

# ============================================================
#  SECTION 4 — VOLUME GROUPS
# ============================================================
section "4. LVM — Volume Groups"
echo ""
if vgs --noheadings 2>/dev/null | grep -q .; then
  printf "  %-20s %-6s %-6s %-12s %-12s\n" 'VG Name' '#PVs' '#LVs' 'VG Size' 'VG Free'
  sep
  VG_TABLE=$(vgs --noheadings --units g --separator '|' \
    -o vg_name,pv_count,lv_count,vg_size,vg_free 2>/dev/null)
  echo "$VG_TABLE" | while IFS='|' read -r vg pvc lvc vsz vfr; do
    fv=$(echo "${vfr// /}" | tr -d 'gG<')
    if awk "BEGIN{exit !($fv < 1)}" 2>/dev/null; then
      printf "  ${ORANGE}%-20s %-6s %-6s %-12s %-12s${RESET}\n" \
        "${vg// /}" "${pvc// /}" "${lvc// /}" "${vsz// /}" "${vfr// /}"
    else
      printf "  %-20s %-6s %-6s %-12s %-12s\n" \
        "${vg// /}" "${pvc// /}" "${lvc// /}" "${vsz// /}" "${vfr// /}"
    fi
  done
  echo ""
  info "Detailed VG info:"
  VG_DETAIL=$(vgdisplay 2>/dev/null | grep -E "VG Name|Format|VG Size|PE Size|Total PE|Alloc PE|Free PE" || true)
  echo "$VG_DETAIL" | while IFS= read -r l; do echo "    $l"; done
else
  warn "No Volume Groups found."
  VG_TABLE=""
  VG_DETAIL=""
fi

# ============================================================
#  SECTION 5 — LOGICAL VOLUMES
# ============================================================
section "5. LVM — Logical Volumes"
echo ""
if lvs --noheadings 2>/dev/null | grep -q .; then
  printf "  %-32s %-18s %-10s %-8s\n" 'LV Path' 'VG Name' 'LV Size' 'Type'
  sep
  LV_TABLE=$(lvs --noheadings --units g --separator '|' \
    -o lv_path,vg_name,lv_size,segtype 2>/dev/null)
  echo "$LV_TABLE" | while IFS='|' read -r lp vg ls st; do
    printf "  %-32s %-18s %-10s %-8s\n" \
      "${lp// /}" "${vg// /}" "${ls// /}" "${st// /}"
  done
  echo ""
  info "Detailed LV info:"
  LV_DETAIL=$(lvdisplay 2>/dev/null | grep -E "LV Path|LV Name|VG Name|LV Size|LV UUID" || true)
  echo "$LV_DETAIL" | while IFS= read -r l; do echo "    $l"; done
else
  warn "No Logical Volumes found."
  LV_TABLE=""
  LV_DETAIL=""
fi

# ============================================================
#  SECTION 6 — FSTAB
# ============================================================
section "6. /etc/fstab — Persistent Mounts"
echo ""
FSTAB_CONTENT=$(cat /etc/fstab 2>/dev/null || echo "Cannot read /etc/fstab")
echo "$FSTAB_CONTENT" | while IFS= read -r line; do echo "  $line"; done

# ============================================================
#  SECTION 7 — INTERACTIVE EXTENSION
# ============================================================
section "7. Interactive — Extend a Logical Volume"
echo ""
info "Review the storage info above before proceeding."
warn "All operations are logged to the HTML report."
echo ""
echo -ne "  ${BOLD}Extend a Logical Volume now? [y/N]: ${RESET}"
read -r PROCEED

if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
  info "Extension skipped by user."
  EXTENSION_SKIPPED=true
else

  # ── 7a: Source of new space ──────────────────────────────
  echo ""
  echo -e "  ${BOLD}Select source of additional disk space:${RESET}"
  echo -e "  ${CYAN}[1]${RESET} New physical disk         (e.g. /dev/sdb)"
  echo -e "  ${CYAN}[2]${RESET} New partition on disk     (e.g. /dev/sda3)"
  echo -e "  ${CYAN}[3]${RESET} VM/cloud disk was resized (growpart + pvresize)"
  echo -e "  ${CYAN}[4]${RESET} VG already has free space (skip to LV extend)"
  echo ""
  echo -ne "  ${BOLD}Choose [1-4]: ${RESET}"
  read -r SRC

  case "$SRC" in
    1|2)
      [[ "$SRC" == "1" ]] && DEV_TYPE="disk" || DEV_TYPE="partition"
      echo ""
      info "Available block devices:"
      lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null
      echo ""
      echo -ne "  ${BOLD}Enter device path (e.g. /dev/sdb): ${RESET}"
      read -r NEW_DEV
      [[ ! -b "$NEW_DEV" ]] && { err "Device ${NEW_DEV} not found."; exit 1; }

      # Check for existing signatures
      EXISTING_SIG=$(wipefs "$NEW_DEV" 2>/dev/null || true)
      if [[ -n "$EXISTING_SIG" ]]; then
        warn "Existing signatures detected on ${NEW_DEV}."
        echo -ne "  ${BOLD}${ORANGE}Wipe ALL signatures on ${NEW_DEV}? [y/N]: ${RESET}"
        read -r WIPE_CONFIRM
        if [[ "$WIPE_CONFIRM" =~ ^[Yy]$ ]]; then
          step "wipefs -a ${NEW_DEV}"
          wipefs -a "$NEW_DEV" 2>&1
          ok "Signatures wiped from ${NEW_DEV}"
          html_step "&#128465; Wipe ${NEW_DEV}" "wipefs -a ${NEW_DEV}" "$(badge ok "DONE")"
        else
          err "Wipe declined. Cannot create PV on device with existing metadata."
          exit 1
        fi
      fi

      step "pvcreate ${NEW_DEV}"
      if ! pvcreate "$NEW_DEV" 2>&1; then
        warn "pvcreate failed — retrying with force flag (-ff) ..."
        echo -ne "  ${BOLD}${ORANGE}Force initialise ${NEW_DEV} with -ff? [y/N]: ${RESET}"
        read -r FORCE_CONFIRM
        if [[ "$FORCE_CONFIRM" =~ ^[Yy]$ ]]; then
          step "pvcreate -ff ${NEW_DEV}"
          echo "y" | pvcreate -ff "$NEW_DEV" 2>&1
          ok "PV force-created: ${NEW_DEV}"
          html_step "&#128190; pvcreate -ff ${NEW_DEV}" "Force initialised" "$(badge ok "DONE")"
        else
          err "Force init declined. Aborting."
          exit 1
        fi
      else
        ok "PV created: ${NEW_DEV}"
        html_step "&#128190; pvcreate ${NEW_DEV}" "Physical Volume created" "$(badge ok "DONE")"
      fi
      NEW_PV="$NEW_DEV"
      ;;

    3)
      echo ""
      lsblk -d -o NAME,SIZE 2>/dev/null
      echo ""
      echo -ne "  ${BOLD}Enter disk (e.g. /dev/sda): ${RESET}"
      read -r GP_DISK
      echo -ne "  ${BOLD}Enter partition number (e.g. 3): ${RESET}"
      read -r GP_NUM
      if ! command -v growpart &>/dev/null; then
        warn "growpart not found — installing cloud-guest-utils ..."
        apt-get install -y cloud-guest-utils 2>&1 | tail -3
      fi
      step "growpart ${GP_DISK} ${GP_NUM}"
      growpart "$GP_DISK" "$GP_NUM" 2>&1
      step "pvresize ${GP_DISK}${GP_NUM}"
      pvresize "${GP_DISK}${GP_NUM}" 2>&1
      ok "Disk resized and PV updated"
      html_step "&#128260; growpart + pvresize" "${GP_DISK} partition ${GP_NUM}" "$(badge ok "DONE")"
      NEW_PV=""
      SRC=4
      ;;

    4)
      info "Using existing VG free space."
      NEW_PV=""
      ;;

    *)
      err "Invalid option."
      exit 1
      ;;
  esac

  # ── 7b: Select Volume Group ──────────────────────────────
  echo ""
  info "Available Volume Groups:"
  vgs 2>/dev/null
  echo ""
  echo -ne "  ${BOLD}Enter VG name (e.g. ubuntu-vg): ${RESET}"
  read -r VG_NAME
  vgs "$VG_NAME" &>/dev/null || { err "VG '${VG_NAME}' not found."; exit 1; }

  # ── Missing PV check & remediation ──────────────────────
  echo ""
  step "Checking VG '${VG_NAME}' for missing Physical Volumes ..."
  MISSING_PV=$(vgs --noheadings -o vg_missing_pv_count "$VG_NAME" 2>/dev/null | tr -d ' ' || echo "0")

  if [[ "$MISSING_PV" =~ ^[0-9]+$ && "$MISSING_PV" -gt 0 ]]; then
    warn "VG '${VG_NAME}' has ${MISSING_PV} missing PV(s) — must be resolved before extending."
    echo ""
    echo -e "  ${BOLD}How do you want to resolve the missing PV?${RESET}"
    echo -e "  ${CYAN}[1]${RESET} Remove missing PV record from VG  ${ORANGE}(disk gone — only if no data was on it)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Restore missing PV back into VG   ${ORANGE}(disk exists but VG lost track of it)${RESET}"
    echo -e "  ${CYAN}[3]${RESET} Abort — fix manually"
    echo ""
    echo -ne "  ${BOLD}Choose [1-3]: ${RESET}"
    read -r MISSING_FIX

    case "$MISSING_FIX" in
      1)
        warn "This permanently removes the missing PV record from VG '${VG_NAME}'."
        echo -ne "  ${BOLD}${RED}Confirm removal? [y/N]: ${RESET}"
        read -r CONFIRM_REDUCE
        if [[ "$CONFIRM_REDUCE" =~ ^[Yy]$ ]]; then
          step "vgreduce --removemissing --force ${VG_NAME}"
          vgreduce --removemissing --force "$VG_NAME" 2>&1
          ok "Missing PV record removed from VG '${VG_NAME}'"
          html_step "&#9888; vgreduce --removemissing" "VG: ${VG_NAME}" "$(badge warn "REMOVED")"
        else
          err "Aborted by user."
          exit 1
        fi
        ;;
      2)
        echo ""
        info "Available block devices:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null
        echo ""
        echo -ne "  ${BOLD}Enter device path of the missing PV (e.g. /dev/sdc): ${RESET}"
        read -r RESTORE_DEV
        [[ ! -b "$RESTORE_DEV" ]] && { err "Device ${RESTORE_DEV} not found."; exit 1; }
        step "vgextend --restoremissing ${VG_NAME} ${RESTORE_DEV}"
        vgextend --restoremissing "$VG_NAME" "$RESTORE_DEV" 2>&1
        ok "Missing PV restored into VG '${VG_NAME}'"
        html_step "&#9881; vgextend --restoremissing" "VG: ${VG_NAME} / PV: ${RESTORE_DEV}" "$(badge ok "RESTORED")"
        ;;
      3)
        warn "Aborted. Fix the missing PV manually then re-run the script."
        warn "Hint: sudo vgreduce --removemissing --force ${VG_NAME}"
        warn "  or: sudo vgextend --restoremissing ${VG_NAME} /dev/sdX"
        exit 0
        ;;
      *)
        err "Invalid option."
        exit 1
        ;;
    esac

    # Final health gate
    STILL_MISSING=$(vgs --noheadings -o vg_missing_pv_count "$VG_NAME" 2>/dev/null | tr -d ' ' || echo "0")
    if [[ "$STILL_MISSING" =~ ^[0-9]+$ && "$STILL_MISSING" -gt 0 ]]; then
      err "VG '${VG_NAME}' still has missing PVs. Cannot proceed safely."
      exit 1
    fi
    ok "VG '${VG_NAME}' is healthy — no missing PVs."
  else
    ok "VG '${VG_NAME}' is healthy — no missing PVs detected."
    html_step "&#9989; VG Health Check" "VG: ${VG_NAME}" "$(badge pass "HEALTHY")"
  fi

  # ── vgextend if a new PV was added ──────────────────────
  if [[ -n "$NEW_PV" ]]; then
    step "vgextend ${VG_NAME} ${NEW_PV}"
    vgextend "$VG_NAME" "$NEW_PV" 2>&1
    ok "VG '${VG_NAME}' extended with ${NEW_PV}"
    html_step "&#128295; vgextend ${VG_NAME}" "Added PV: ${NEW_PV}" "$(badge ok "DONE")"
  fi

  # ── 7c: Select Logical Volume ────────────────────────────
  echo ""
  info "Logical Volumes in '${VG_NAME}':"
  lvs "$VG_NAME" 2>/dev/null
  echo ""
  echo -ne "  ${BOLD}Enter LV path (e.g. /dev/ubuntu-vg/ubuntu-lv): ${RESET}"
  read -r LV_PATH
  lvs "$LV_PATH" &>/dev/null || { err "LV '${LV_PATH}' not found."; exit 1; }
  html_step "&#128190; Selected LV" "${LV_PATH}" "$(badge ok "FOUND")"

  # ── 7d: Size to add ──────────────────────────────────────
  echo ""
  echo -e "  ${BOLD}How much space to add?${RESET}"
  echo -e "  ${CYAN}[1]${RESET} Use ALL available free space in VG"
  echo -e "  ${CYAN}[2]${RESET} Specify exact amount (e.g. 50G)"
  echo ""
  echo -ne "  ${BOLD}Choose [1/2]: ${RESET}"
  read -r SZ_OPT

  if [[ "$SZ_OPT" == "1" ]]; then
    step "lvextend -l +100%FREE ${LV_PATH}"
    LVEXT_OUT=$(lvextend -l +100%FREE "$LV_PATH" 2>&1 || true)
    echo "$LVEXT_OUT"
    if echo "$LVEXT_OUT" | grep -qi "missing\|Cannot process\|PVs are missing"; then
      err "lvextend failed — VG has missing PVs."
      exit 1
    fi
    ok "LV extended using all free space"
    html_step "&#8679; lvextend 100%FREE" "LV: ${LV_PATH}" "$(badge pass "EXTENDED")"
    ADD_SZ="100%FREE"

  elif [[ "$SZ_OPT" == "2" ]]; then
    echo -ne "  ${BOLD}Enter size (e.g. 50G): ${RESET}"
    read -r ADD_SZ
    step "lvextend -L +${ADD_SZ} ${LV_PATH}"
    LVEXT_OUT=$(lvextend -L "+${ADD_SZ}" "$LV_PATH" 2>&1 || true)
    echo "$LVEXT_OUT"
    if echo "$LVEXT_OUT" | grep -qi "missing\|Cannot process\|PVs are missing"; then
      err "lvextend failed — VG has missing PVs."
      exit 1
    elif echo "$LVEXT_OUT" | grep -qi "successfully resized"; then
      ok "LV extended by ${ADD_SZ}"
      html_step "&#8679; lvextend +${ADD_SZ}" "LV: ${LV_PATH}" "$(badge pass "EXTENDED")"
    else
      err "lvextend failed. Insufficient space or invalid size."
      exit 1
    fi
  else
    err "Invalid option."
    exit 1
  fi

  # ── 7e: Filesystem resize ────────────────────────────────
  echo ""
  FS_TYPE=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null || echo "unknown")
  info "Filesystem detected: ${FS_TYPE}"

  case "$FS_TYPE" in
    ext2|ext3|ext4)
      step "resize2fs ${LV_PATH}"
      resize2fs "$LV_PATH" 2>&1
      ok "Filesystem resized (resize2fs)"
      html_step "&#128196; resize2fs" "LV: ${LV_PATH} / FS: ${FS_TYPE}" "$(badge pass "RESIZED")"
      ;;
    xfs)
      MP=$(findmnt -n -o TARGET "$LV_PATH" 2>/dev/null || echo "/")
      step "xfs_growfs ${MP}"
      xfs_growfs "$MP" 2>&1
      ok "Filesystem resized (xfs_growfs on ${MP})"
      html_step "&#128196; xfs_growfs" "Mount: ${MP} / FS: xfs" "$(badge pass "RESIZED")"
      ;;
    *)
      warn "Unknown filesystem '${FS_TYPE}'. Resize manually:"
      warn "  ext4: sudo resize2fs ${LV_PATH}"
      warn "  xfs:  sudo xfs_growfs <mountpoint>"
      html_step "&#9888; Filesystem Resize" "Type '${FS_TYPE}' — manual resize required" "$(badge warn "MANUAL")"
      ;;
  esac

  EXTENSION_DONE=true

fi  # end PROCEED block

# ============================================================
#  SECTION 8 — POST-EXTENSION STATE
# ============================================================
section "8. Post-Extension Storage State"
echo ""
info "Updated filesystem usage:"
POST_DF=$(df -h 2>/dev/null)
echo "$POST_DF" | while IFS= read -r l; do echo "  $l"; done
echo ""
info "Updated PVs:"
POST_PV=$(pvs 2>/dev/null || echo "N/A")
echo "$POST_PV" | while IFS= read -r l; do echo "  $l"; done
echo ""
info "Updated VGs:"
POST_VG=$(vgs 2>/dev/null || echo "N/A")
echo "$POST_VG" | while IFS= read -r l; do echo "  $l"; done
echo ""
info "Updated LVs:"
POST_LV=$(lvs 2>/dev/null || echo "N/A")
echo "$POST_LV" | while IFS= read -r l; do echo "  $l"; done

# ============================================================
#  TERMINAL — OVERALL RESULT
# ============================================================
sep
if $EXTENSION_DONE; then
  echo -e "  ${GREEN}${BOLD}  OVERALL: COMPLETE — LVM extension finished successfully${RESET}"
elif $EXTENSION_SKIPPED; then
  echo -e "  ${CYAN}${BOLD}  OVERALL: SKIPPED — Audit report saved, no changes made${RESET}"
else
  echo -e "  ${ORANGE}${BOLD}  OVERALL: ABORTED${RESET}"
fi
echo ""

# ============================================================
#  GENERATE HTML REPORT
# ============================================================
mkdir -p "$REPORT_DIR"

# Determine overall verdict for HTML
if $EXTENSION_DONE; then
  overall_class="pass"
  overall_icon="&#10004;"
  overall_msg="LVM extension completed successfully"
elif $EXTENSION_SKIPPED; then
  overall_class="info"
  overall_icon="&#8505;"
  overall_msg="Audit only — no changes made"
else
  overall_class="fail"
  overall_icon="&#10008;"
  overall_msg="Extension aborted"
fi

# Escape and format table data for HTML
escape_html() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

build_table() {
  local content="$1"
  local out=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    out+="<tr>"
    while IFS= read -rd $'\t' cell || [[ -n "$cell" ]]; do
      out+="<td>$(escape_html "$cell")</td>"
    done <<< "$line"
    out+="</tr>"
  done <<< "$content"
  echo "$out"
}

# Build pre-formatted blocks for HTML sections
FS_HTML=$(escape_html "$FS_TABLE")
LSBLK_HTML=$(escape_html "$LSBLK_OUT")
PV_HTML=$(escape_html "${PV_TABLE:-No Physical Volumes found}")
PV_DETAIL_HTML=$(escape_html "${PV_DETAIL:-}")
VG_HTML=$(escape_html "${VG_TABLE:-No Volume Groups found}")
VG_DETAIL_HTML=$(escape_html "${VG_DETAIL:-}")
LV_HTML=$(escape_html "${LV_TABLE:-No Logical Volumes found}")
LV_DETAIL_HTML=$(escape_html "${LV_DETAIL:-}")
FSTAB_HTML=$(escape_html "$FSTAB_CONTENT")
POST_DF_HTML=$(escape_html "$POST_DF")
POST_PV_HTML=$(escape_html "$POST_PV")
POST_VG_HTML=$(escape_html "$POST_VG")
POST_LV_HTML=$(escape_html "$POST_LV")

MISSING_TOOLS_HTML=""
if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  MISSING_TOOLS_HTML="<div class=\"verdict warn\" style=\"margin-bottom:20px;\">
    <span class=\"icon\">&#9888;</span>
    Missing tools: ${MISSING_TOOLS[*]} &mdash; install lvm2 package
  </div>"
fi

cat > "$REPORT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>LVM Extension Report &mdash; ${TIMESTAMP}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Syne:wght@400;700;800&display=swap');

  :root {
    --bg:        #0b0e14;
    --surface:   #111620;
    --surface2:  #181e2c;
    --border:    #1f2a3d;
    --text:      #c8d6ef;
    --muted:     #5a6a88;
    --pass:      #22c55e;
    --pass-bg:   #052613;
    --fail:      #ef4444;
    --fail-bg:   #2a0808;
    --warn:      #f59e0b;
    --warn-bg:   #271a02;
    --info:      #3b82f6;
    --info-bg:   #0c1a35;
    --ok:        #22c55e;
    --ok-bg:     #052613;
    --accent:    #3b82f6;
    --mono:      'JetBrains Mono', monospace;
    --display:   'Syne', sans-serif;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--mono);
    font-size: 14px;
    line-height: 1.6;
    min-height: 100vh;
    padding: 40px 20px 80px;
  }

  body::before {
    content: '';
    position: fixed;
    inset: 0;
    background-image:
      linear-gradient(var(--border) 1px, transparent 1px),
      linear-gradient(90deg, var(--border) 1px, transparent 1px);
    background-size: 40px 40px;
    opacity: 0.22;
    pointer-events: none;
    z-index: 0;
  }

  .wrapper {
    position: relative;
    z-index: 1;
    max-width: 900px;
    margin: 0 auto;
  }

  header {
    margin-bottom: 36px;
    border-left: 3px solid var(--accent);
    padding-left: 20px;
  }
  header .pre-label {
    font-size: 11px;
    letter-spacing: 0.2em;
    color: var(--accent);
    text-transform: uppercase;
    margin-bottom: 6px;
  }
  header h1 {
    font-family: var(--display);
    font-size: 2rem;
    font-weight: 800;
    color: #e8f0ff;
    letter-spacing: -0.02em;
    line-height: 1.1;
    margin-bottom: 8px;
  }
  header .meta { font-size: 12px; color: var(--muted); }

  .verdict {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 18px 24px;
    border-radius: 10px;
    margin-bottom: 32px;
    font-family: var(--display);
    font-size: 1.05rem;
    font-weight: 700;
    letter-spacing: 0.04em;
    border: 1px solid;
  }
  .verdict.pass { background: var(--pass-bg); border-color: var(--pass); color: var(--pass); }
  .verdict.fail { background: var(--fail-bg); border-color: var(--fail); color: var(--fail); }
  .verdict.warn { background: var(--warn-bg); border-color: var(--warn); color: var(--warn); }
  .verdict.info { background: var(--info-bg); border-color: var(--info); color: var(--info); }
  .verdict .icon { font-size: 1.4rem; }

  .section-title {
    font-family: var(--display);
    font-size: 0.65rem;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border);
  }

  .os-info {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    margin-bottom: 32px;
  }
  .os-info-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
  }
  .os-cell {
    padding: 16px 20px;
    border-right: 1px solid var(--border);
    border-bottom: 1px solid var(--border);
  }
  .os-cell:nth-child(3n) { border-right: none; }
  .os-cell:nth-last-child(-n+3) { border-bottom: none; }
  .os-cell .os-key {
    font-size: 10px;
    letter-spacing: 0.13em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 4px;
  }
  .os-cell .os-val { font-size: 13px; font-weight: 600; color: #e8f0ff; word-break: break-word; }

  .code-panel {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    margin-bottom: 24px;
  }
  .code-panel-title {
    background: var(--surface2);
    padding: 10px 18px;
    font-size: 11px;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--muted);
    border-bottom: 1px solid var(--border);
  }
  .code-panel pre {
    padding: 16px 18px;
    font-family: var(--mono);
    font-size: 12px;
    color: #7dd3fc;
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.8;
    margin: 0;
    overflow-x: auto;
  }

  .tool-table {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    margin-bottom: 32px;
  }
  .tool-row {
    display: grid;
    grid-template-columns: 220px 1fr auto;
    align-items: center;
    padding: 14px 20px;
    border-bottom: 1px solid var(--border);
    gap: 14px;
  }
  .tool-row:last-child { border-bottom: none; }
  .tool-name { font-weight: 600; font-size: 13px; }
  .tool-detail { color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  .code-block {
    background: #0a0e13;
    border-left: 2px solid var(--accent);
    margin: 0;
    padding: 12px 18px 12px 20px;
    border-bottom: 1px solid var(--border);
  }
  .code-block:last-child { border-bottom: none; }
  .code-title {
    font-size: 10px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 6px;
  }
  .code-block pre {
    font-family: var(--mono);
    font-size: 12px;
    color: #7dd3fc;
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.7;
    margin: 0;
  }

  .badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .badge.pass    { background: var(--pass-bg); color: var(--pass); border: 1px solid var(--pass); }
  .badge.fail    { background: var(--fail-bg); color: var(--fail); border: 1px solid var(--fail); }
  .badge.warn    { background: var(--warn-bg); color: var(--warn); border: 1px solid var(--warn); }
  .badge.ok      { background: var(--ok-bg);   color: var(--ok);   border: 1px solid var(--ok);  }
  .badge.info    { background: var(--info-bg); color: var(--info); border: 1px solid var(--info);}

  .legend {
    background: var(--surface2);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-bottom: 32px;
    font-size: 12px;
  }
  .legend-row { display: flex; align-items: center; gap: 12px; color: var(--muted); }

  footer {
    text-align: center;
    color: var(--muted);
    font-size: 11px;
    letter-spacing: 0.08em;
    border-top: 1px solid var(--border);
    padding-top: 20px;
  }

  @media (max-width: 640px) {
    .os-info-grid { grid-template-columns: 1fr; }
    .tool-row { grid-template-columns: 1fr auto; }
    .tool-name { grid-column: 1 / -1; }
  }
</style>
</head>
<body>
<div class="wrapper">

  <header>
    <div class="pre-label">// lvm volume extension utility</div>
    <h1>LVM Extension Report</h1>
    <div class="meta">Generated: ${DATE_HUMAN}</div>
    <div class="meta">Host: ${HOST_NAME} &nbsp;|&nbsp; Kernel: ${OS_KERNEL} &nbsp;|&nbsp; Arch: ${OS_ARCH}</div>
  </header>

  ${MISSING_TOOLS_HTML}

  <div class="verdict ${overall_class}">
    <span class="icon">${overall_icon}</span>
    OVERALL: ${overall_msg}
  </div>

  <div class="section-title">Operating System</div>
  <div class="os-info">
    <div class="os-info-grid">
      <div class="os-cell"><div class="os-key">OS Name</div><div class="os-val">${OS_NAME}</div></div>
      <div class="os-cell"><div class="os-key">Version</div><div class="os-val">${OS_VERSION}</div></div>
      <div class="os-cell"><div class="os-key">Codename</div><div class="os-val">${OS_CODENAME}</div></div>
      <div class="os-cell"><div class="os-key">Distribution ID</div><div class="os-val">${OS_ID}</div></div>
      <div class="os-cell"><div class="os-key">Kernel</div><div class="os-val">${OS_KERNEL}</div></div>
      <div class="os-cell"><div class="os-key">Architecture</div><div class="os-val">${OS_ARCH}</div></div>
    </div>
  </div>

  <div class="section-title">1. Filesystem &amp; Mount Points</div>
  <div class="code-panel">
    <div class="code-panel-title">df -h &mdash; colour: red &ge;90% used &nbsp;|&nbsp; orange &ge;70% used</div>
    <pre>${FS_HTML}</pre>
  </div>

  <div class="section-title">2. Block Devices</div>
  <div class="code-panel">
    <div class="code-panel-title">lsblk</div>
    <pre>${LSBLK_HTML}</pre>
  </div>

  <div class="section-title">3. LVM &mdash; Physical Volumes</div>
  <div class="code-panel">
    <div class="code-panel-title">pvs summary</div>
    <pre>${PV_HTML}</pre>
  </div>
  <div class="code-panel">
    <div class="code-panel-title">pvdisplay detail</div>
    <pre>${PV_DETAIL_HTML:-No detail available}</pre>
  </div>

  <div class="section-title">4. LVM &mdash; Volume Groups</div>
  <div class="code-panel">
    <div class="code-panel-title">vgs summary &mdash; orange = VG free &lt; 1 GB</div>
    <pre>${VG_HTML}</pre>
  </div>
  <div class="code-panel">
    <div class="code-panel-title">vgdisplay detail</div>
    <pre>${VG_DETAIL_HTML:-No detail available}</pre>
  </div>

  <div class="section-title">5. LVM &mdash; Logical Volumes</div>
  <div class="code-panel">
    <div class="code-panel-title">lvs summary</div>
    <pre>${LV_HTML}</pre>
  </div>
  <div class="code-panel">
    <div class="code-panel-title">lvdisplay detail</div>
    <pre>${LV_DETAIL_HTML:-No detail available}</pre>
  </div>

  <div class="section-title">6. /etc/fstab &mdash; Persistent Mounts</div>
  <div class="code-panel">
    <div class="code-panel-title">/etc/fstab</div>
    <pre>${FSTAB_HTML}</pre>
  </div>

  <div class="section-title">7. Extension Actions</div>
  <div class="tool-table">
    $(if $EXTENSION_SKIPPED; then
      echo "<div class=\"tool-row\"><div class=\"tool-name\">&#9654; Extension</div><div class=\"tool-detail\">Skipped by user — audit only</div><div><span class=\"badge info\">SKIPPED</span></div></div>"
    else
      echo "${HTML_STEPS}"
    fi)
  </div>

  <div class="section-title">8. Post-Extension Storage State</div>
  <div class="code-panel">
    <div class="code-panel-title">df -h (after)</div>
    <pre>${POST_DF_HTML}</pre>
  </div>
  <div class="code-panel">
    <div class="code-panel-title">pvs (after)</div>
    <pre>${POST_PV_HTML}</pre>
  </div>
  <div class="code-panel">
    <div class="code-panel-title">vgs (after)</div>
    <pre>${POST_VG_HTML}</pre>
  </div>
  <div class="code-panel">
    <div class="code-panel-title">lvs (after)</div>
    <pre>${POST_LV_HTML}</pre>
  </div>

  <div class="section-title">Legend</div>
  <div class="legend">
    <div class="legend-row"><span class="badge pass">COMPLETE / HEALTHY / EXTENDED / RESIZED</span> Operation completed successfully</div>
    <div class="legend-row"><span class="badge warn">WARNING / MANUAL / REMOVED</span> Advisory or action requiring attention</div>
    <div class="legend-row"><span class="badge fail">FAIL / ABORTED</span> Operation failed or was aborted</div>
    <div class="legend-row"><span class="badge info">SKIPPED</span> Extension not performed &mdash; audit report only</div>
  </div>

  <footer>
    lvm_extend.sh &nbsp;&middot;&nbsp; Report: ${REPORT_FILE}
  </footer>

</div>
</body>
</html>
HTMLEOF

echo -e "${CYAN}  HTML report saved:${RESET} ${REPORT_FILE}\n"
