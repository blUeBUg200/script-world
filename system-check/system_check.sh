#!/usr/bin/env bash
# ============================================================
#  system_check.sh — Pre-flight system requirements checker
#  Usage: ./system_check.sh --cpu <cores> --ram <GB> --storage <GB> [--mount <path>]
#  Example: ./system_check.sh --cpu 4 --ram 16 --storage 100 --mount /data
#
#  Notes:
#    --mount   Mount point to check for free storage (default: /)
#              RAM and Storage are passed with a ±2 GB tolerance:
#              values within 2 GB below the requirement still PASS.
# ============================================================

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────
REQ_CPU=""
REQ_RAM=""
REQ_STORAGE=""
MOUNT_POINT="/"          # default mount point; override with --mount
TOLERANCE=2              # GB tolerance applied to RAM and Storage
REPORT_DIR="$(pwd)/system_reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
REPORT_FILE="${REPORT_DIR}/report_${TIMESTAMP}.html"
DATE_HUMAN=$(date '+%A, %d %B %Y — %H:%M:%S %Z')

# ── Colours (terminal) ──────────────────────────────────────
RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Usage ────────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}Usage:${RESET} $0 --cpu <cores> --ram <GB> --storage <GB> [--mount <path>]"
  echo ""
  echo "  --cpu      Required CPU cores (integer)"
  echo "  --ram      Required RAM in GB (integer)"
  echo "  --storage  Required free disk space in GB (integer)"
  echo "  --mount    Mount point to check for storage (default: /)"
  echo ""
  echo "  Note: RAM and Storage pass with a ±${TOLERANCE} GB tolerance."
  echo ""
  echo "Example:"
  echo "  $0 --cpu 4 --ram 16 --storage 100"
  echo "  $0 --cpu 4 --ram 16 --storage 100 --mount /data"
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)      REQ_CPU="$2";      shift 2 ;;
    --ram)      REQ_RAM="$2";      shift 2 ;;
    --storage)  REQ_STORAGE="$2";  shift 2 ;;
    --mount)    MOUNT_POINT="$2";  shift 2 ;;
    -h|--help)  usage ;;
    *) echo -e "${RED}Unknown argument: $1${RESET}"; usage ;;
  esac
done

[[ -z "$REQ_CPU" || -z "$REQ_RAM" || -z "$REQ_STORAGE" ]] && {
  echo -e "${RED}Error: --cpu, --ram, and --storage are all required.${RESET}"
  usage
}

# Validate mount point
if [[ ! -d "$MOUNT_POINT" ]]; then
  echo -e "${RED}Error: Mount point '${MOUNT_POINT}' does not exist.${RESET}"
  exit 1
fi

# ── Gather system info ───────────────────────────────────────
echo -e "\n${CYAN}${BOLD}  Running system checks...${RESET}\n"

## CPU
SYS_CPU=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)

## RAM (in GB, rounded)
SYS_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
SYS_RAM=$(( SYS_RAM_KB / 1024 / 1024 ))

## Storage — free space on the specified mount point
SYS_STORAGE=$(df -BG "${MOUNT_POINT}" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo 0)

## Firewall
FW_STATUS="unknown"
FW_DETAIL=""
if command -v ufw &>/dev/null; then
  FW_RAW=$(ufw status 2>/dev/null | head -1 || true)
  if echo "$FW_RAW" | grep -qi "active"; then
    FW_STATUS="active"
    FW_DETAIL="ufw: active"
  else
    FW_STATUS="inactive"
    FW_DETAIL="ufw: inactive"
  fi
elif command -v firewall-cmd &>/dev/null; then
  if firewall-cmd --state 2>/dev/null | grep -qi "running"; then
    FW_STATUS="active"
    FW_DETAIL="firewalld: running"
  else
    FW_STATUS="inactive"
    FW_DETAIL="firewalld: not running"
  fi
elif command -v iptables &>/dev/null; then
  RULES=$(iptables -L 2>/dev/null | grep -cv "^Chain\|^target\|^$" || echo 0)
  if [[ "$RULES" -gt 0 ]]; then
    FW_STATUS="active"
    FW_DETAIL="iptables: $RULES rules detected"
  else
    FW_STATUS="inactive"
    FW_DETAIL="iptables: no rules"
  fi
else
  FW_STATUS="not_found"
  FW_DETAIL="No recognised firewall tool found"
fi

## Docker
DOCKER_AVAILABLE="no"
DOCKER_VERSION=""
if command -v docker &>/dev/null; then
  DOCKER_AVAILABLE="yes"
  DOCKER_VERSION=$(docker --version 2>/dev/null | sed 's/Docker version //' || echo "unknown")
fi

## Docker Compose
COMPOSE_AVAILABLE="no"
COMPOSE_VERSION=""
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_AVAILABLE="yes"
  COMPOSE_VERSION=$(docker compose version 2>/dev/null | head -1 || echo "unknown")
elif command -v docker-compose &>/dev/null; then
  COMPOSE_AVAILABLE="yes"
  COMPOSE_VERSION=$(docker-compose --version 2>/dev/null || echo "unknown (v1 standalone)")
fi

## Curl
CURL_AVAILABLE="no"
CURL_VERSION=""
if command -v curl &>/dev/null; then
  CURL_AVAILABLE="yes"
  CURL_VERSION=$(curl --version 2>/dev/null | head -1 | awk '{print $1" "$2}' || echo "unknown")
fi

## OS Release
OS_NAME="unknown"
OS_VERSION="unknown"
OS_ID="unknown"
OS_ID_LIKE="unknown"
OS_CODENAME="unknown"
OS_KERNEL=$(uname -r 2>/dev/null || echo "unknown")
OS_ARCH=$(uname -m 2>/dev/null || echo "unknown")
HOST_NAME=$(hostname 2>/dev/null || echo "unknown")

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-unknown}"
  OS_VERSION="${VERSION:-${VERSION_ID:-unknown}}"
  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-${ID:-unknown}}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-n/a}}"
elif [[ -f /etc/redhat-release ]]; then
  OS_NAME=$(cat /etc/redhat-release)
  OS_VERSION="unknown"
  OS_ID="rhel"
  OS_ID_LIKE="rhel"
  OS_CODENAME="n/a"
elif command -v lsb_release &>/dev/null; then
  OS_NAME=$(lsb_release -ds 2>/dev/null || echo "unknown")
  OS_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
  OS_ID=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
  OS_ID_LIKE="$OS_ID"
  OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "n/a")
fi

# ── Install instruction builder ──────────────────────────────
# Detect package manager family from OS_ID / OS_ID_LIKE
PKG_FAMILY="unknown"
case "${OS_ID}" in
  ubuntu|debian|linuxmint|pop|elementary|kali|raspbian) PKG_FAMILY="apt" ;;
  rhel|centos|fedora|rocky|almalinux|ol|amzn)          PKG_FAMILY="rpm" ;;
  arch|manjaro|endeavouros)                             PKG_FAMILY="pacman" ;;
  opensuse*|sles)                                       PKG_FAMILY="zypper" ;;
  alpine)                                               PKG_FAMILY="apk" ;;
esac
# fallback: check OS_ID_LIKE
if [[ "$PKG_FAMILY" == "unknown" ]]; then
  case "${OS_ID_LIKE}" in
    *debian*|*ubuntu*) PKG_FAMILY="apt" ;;
    *rhel*|*fedora*)   PKG_FAMILY="rpm" ;;
    *arch*)            PKG_FAMILY="pacman" ;;
    *suse*)            PKG_FAMILY="zypper" ;;
  esac
fi

# Returns install steps for a given package (docker|compose|curl)
install_steps() {
  local pkg="$1"
  case "$pkg" in
    docker)
      case "$PKG_FAMILY" in
        apt) echo "sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker \$USER" ;;
        rpm)  echo "sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker \$USER" ;;
        pacman) echo "sudo pacman -Sy --noconfirm docker
sudo systemctl enable --now docker
sudo usermod -aG docker \$USER" ;;
        zypper) echo "sudo zypper install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker \$USER" ;;
        apk)  echo "sudo apk add docker
sudo rc-update add docker default
sudo service docker start
sudo addgroup \$USER docker" ;;
        *)    echo "# Visit https://docs.docker.com/engine/install/ for your distro" ;;
      esac ;;

    compose)
      # Docker Compose v2 is a Docker plugin — install alongside Docker
      case "$PKG_FAMILY" in
        apt) echo "# Docker Compose v2 (plugin — preferred)
sudo apt-get update
sudo apt-get install -y docker-compose-plugin
docker compose version

# --- OR standalone v2 binary ---
COMPOSE_VERSION=\$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '\"tag_name\"' | cut -d'\"' -f4)
sudo curl -SL \"https://github.com/docker/compose/releases/download/\${COMPOSE_VERSION}/docker-compose-linux-\$(uname -m)\" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose" ;;
        rpm)  echo "# Docker Compose v2 (plugin — preferred)
sudo yum install -y docker-compose-plugin
docker compose version

# --- OR standalone v2 binary ---
COMPOSE_VERSION=\$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '\"tag_name\"' | cut -d'\"' -f4)
sudo curl -SL \"https://github.com/docker/compose/releases/download/\${COMPOSE_VERSION}/docker-compose-linux-\$(uname -m)\" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose" ;;
        pacman) echo "sudo pacman -Sy --noconfirm docker-compose" ;;
        zypper) echo "sudo zypper install -y docker-compose" ;;
        apk)  echo "sudo apk add docker-compose" ;;
        *)    echo "# Visit https://docs.docker.com/compose/install/ for your distro" ;;
      esac ;;

    curl)
      case "$PKG_FAMILY" in
        apt)    echo "sudo apt-get update && sudo apt-get install -y curl" ;;
        rpm)    echo "sudo yum install -y curl" ;;
        pacman) echo "sudo pacman -Sy --noconfirm curl" ;;
        zypper) echo "sudo zypper install -y curl" ;;
        apk)    echo "sudo apk add curl" ;;
        *)      echo "# Install curl using your system package manager" ;;
      esac ;;
  esac
}

# Pre-build install steps for missing packages (used in terminal + HTML)
DOCKER_INSTALL_STEPS=""
COMPOSE_INSTALL_STEPS=""
CURL_INSTALL_STEPS=""


CPU_PASS=false;  [[ "$SYS_CPU" -ge "$REQ_CPU" ]] && CPU_PASS=true

# RAM: pass if within tolerance (REQ - TOLERANCE)
RAM_EFFECTIVE=$(( REQ_RAM - TOLERANCE ))
RAM_PASS=false;  [[ "$SYS_RAM" -ge "$RAM_EFFECTIVE" ]] && RAM_PASS=true
RAM_NOTE=""
if $RAM_PASS && [[ "$SYS_RAM" -lt "$REQ_RAM" ]]; then
  RAM_NOTE=" (within ${TOLERANCE}GB tolerance)"
fi

# Storage: pass if within tolerance (REQ - TOLERANCE)
STOR_EFFECTIVE=$(( REQ_STORAGE - TOLERANCE ))
STOR_PASS=false; [[ "$SYS_STORAGE" -ge "$STOR_EFFECTIVE" ]] && STOR_PASS=true
STOR_NOTE=""
if $STOR_PASS && [[ "$SYS_STORAGE" -lt "$REQ_STORAGE" ]]; then
  STOR_NOTE=" (within ${TOLERANCE}GB tolerance)"
fi

FW_WARN=false;      [[ "$FW_STATUS" == "active" ]]     && FW_WARN=true
DOCKER_WARN=false;  [[ "$DOCKER_AVAILABLE"  == "no" ]] && DOCKER_WARN=true
COMPOSE_WARN=false; [[ "$COMPOSE_AVAILABLE" == "no" ]] && COMPOSE_WARN=true
CURL_WARN=false;    [[ "$CURL_AVAILABLE"    == "no" ]] && CURL_WARN=true

# Now DOCKER_WARN etc. are set — build install steps
$DOCKER_WARN  && DOCKER_INSTALL_STEPS=$(install_steps docker)
$COMPOSE_WARN && COMPOSE_INSTALL_STEPS=$(install_steps compose)
$CURL_WARN    && CURL_INSTALL_STEPS=$(install_steps curl)

OVERALL="PASS"
$CPU_PASS  || OVERALL="FAIL"
$RAM_PASS  || OVERALL="FAIL"
$STOR_PASS || OVERALL="FAIL"

# ── Terminal summary ─────────────────────────────────────────
echo -e "${BOLD}  System Check Report${RESET}"
echo -e "  Date: ${DATE_HUMAN}"
echo -e "  ─────────────────────────────────────────────────────"

check_line() {
  local label="$1" value="$2" req="$3" pass="$4"
  if [[ "$pass" == "true" ]]; then
    echo -e "  ${GREEN}[PASS]${RESET}  ${label}  system: ${value}  |  required: ${req}"
  else
    echo -e "  ${RED}[FAIL]${RESET}  ${label}  system: ${value}  |  required: ${req}"
  fi
}

warn_line() {
  local label="$1" detail="$2" warn="$3"
  if [[ "$warn" == "true" ]]; then
    echo -e "  ${ORANGE}[WARN]${RESET}  ${label}  ${detail}"
  else
    echo -e "  ${GREEN}[ OK ]${RESET}  ${label}  ${detail}"
  fi
}

echo -e "  ${CYAN}[ OS ]${RESET}  OS              ${OS_NAME}"
echo -e "  ${CYAN}[ OS ]${RESET}  Version         ${OS_VERSION} (${OS_CODENAME})"
echo -e "  ${CYAN}[ OS ]${RESET}  Kernel          ${OS_KERNEL}"
echo -e "  ${CYAN}[ OS ]${RESET}  Architecture    ${OS_ARCH}"
echo -e "  ${CYAN}[ OS ]${RESET}  Hostname        ${HOST_NAME}"
echo -e "  ─────────────────────────────────────────────────────"

check_line "CPU Cores   " "${SYS_CPU} cores"              "${REQ_CPU} cores"      "$CPU_PASS"
check_line "RAM         " "${SYS_RAM} GB${RAM_NOTE}"       "${REQ_RAM} GB (±${TOLERANCE}GB)" "$RAM_PASS"
check_line "Free Disk   " "${SYS_STORAGE} GB${STOR_NOTE}"  "${REQ_STORAGE} GB (±${TOLERANCE}GB) [${MOUNT_POINT}]" "$STOR_PASS"

echo -e "  ─────────────────────────────────────────────────────"

warn_line "Firewall    " "$FW_DETAIL"                    "$FW_WARN"
warn_line "Docker      " "${DOCKER_VERSION:-not found}"  "$DOCKER_WARN"
warn_line "DockerCompose" "${COMPOSE_VERSION:-not found}" "$COMPOSE_WARN"
warn_line "Curl        " "${CURL_VERSION:-not found}"    "$CURL_WARN"

# ── Terminal install hints ────────────────────────────────────
MISSING_ANY=false
$DOCKER_WARN  && MISSING_ANY=true
$COMPOSE_WARN && MISSING_ANY=true
$CURL_WARN    && MISSING_ANY=true

if $MISSING_ANY; then
  echo ""
  echo -e "  ${ORANGE}${BOLD}  Install Instructions (detected: ${OS_NAME} / ${PKG_FAMILY})${RESET}"
  echo -e "  ─────────────────────────────────────────────────────"

  print_install() {
    local label="$1" steps="$2"
    echo -e "\n  ${BOLD}  ▸ ${label}${RESET}"
    while IFS= read -r line; do
      echo -e "    ${CYAN}${line}${RESET}"
    done <<< "$steps"
  }

  $DOCKER_WARN  && print_install "Install Docker"         "$DOCKER_INSTALL_STEPS"
  $COMPOSE_WARN && print_install "Install Docker Compose" "$COMPOSE_INSTALL_STEPS"
  $CURL_WARN    && print_install "Install Curl"           "$CURL_INSTALL_STEPS"
  echo ""
fi

echo -e "  ─────────────────────────────────────────────────────"
if [[ "$OVERALL" == "PASS" ]]; then
  echo -e "  ${GREEN}${BOLD}  OVERALL: PASS${RESET}"
else
  echo -e "  ${RED}${BOLD}  OVERALL: FAIL — resource requirements not met${RESET}"
fi
echo ""

# ── Generate HTML report ─────────────────────────────────────
mkdir -p "$REPORT_DIR"

# Helper: emit HTML badge markup
badge() {
  local type="$1" text="$2"
  echo "<span class=\"badge ${type}\">${text}</span>"
}

# Determine badge class + label for each check
$CPU_PASS   && cpu_badge=$(badge pass "PASS")    || cpu_badge=$(badge fail "FAIL")
$RAM_PASS   && ram_badge=$(badge pass "PASS")    || ram_badge=$(badge fail "FAIL")
$STOR_PASS  && stor_badge=$(badge pass "PASS")   || stor_badge=$(badge fail "FAIL")
$FW_WARN    && fw_badge=$(badge warn "WARNING")  || fw_badge=$(badge ok "OK")
$DOCKER_WARN  && docker_badge=$(badge warn "MISSING")  || docker_badge=$(badge ok "FOUND")
$COMPOSE_WARN && compose_badge=$(badge warn "MISSING") || compose_badge=$(badge ok "FOUND")
$CURL_WARN    && curl_badge=$(badge warn "MISSING")    || curl_badge=$(badge ok "FOUND")

overall_class="pass"; [[ "$OVERALL" == "FAIL" ]] && overall_class="fail"
overall_icon="&#10004;"; [[ "$OVERALL" == "FAIL" ]] && overall_icon="&#10008;"
overall_msg="All resource requirements satisfied"
[[ "$OVERALL" == "FAIL" ]] && overall_msg="One or more resource requirements not met"

KERNEL_VER="$OS_KERNEL"

# Meter percentages (capped at 100, measured against effective thresholds)
cpu_pct=$(( SYS_CPU * 100 / (REQ_CPU > 0 ? REQ_CPU : 1) ))
[[ $cpu_pct -gt 100 ]] && cpu_pct=100
ram_pct=$(( SYS_RAM * 100 / (RAM_EFFECTIVE > 0 ? RAM_EFFECTIVE : 1) ))
[[ $ram_pct -gt 100 ]] && ram_pct=100
stor_pct=$(( SYS_STORAGE * 100 / (STOR_EFFECTIVE > 0 ? STOR_EFFECTIVE : 1) ))
[[ $stor_pct -gt 100 ]] && stor_pct=100

cpu_card_cls="pass";  $CPU_PASS  || cpu_card_cls="fail"
ram_card_cls="pass";  $RAM_PASS  || ram_card_cls="fail"
stor_card_cls="pass"; $STOR_PASS || stor_card_cls="fail"

cat > "$REPORT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>System Check &mdash; ${TIMESTAMP}</title>
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
    max-width: 860px;
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

  header .meta {
    font-size: 12px;
    color: var(--muted);
  }

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

  .req-box {
    background: var(--surface2);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px 22px;
    display: flex;
    gap: 36px;
    flex-wrap: wrap;
    margin-bottom: 32px;
  }
  .req-item .req-key {
    font-size: 10px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 2px;
  }
  .req-item .req-val {
    font-weight: 600;
    color: var(--accent);
    font-size: 15px;
  }

  .cards {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 14px;
    margin-bottom: 32px;
  }
  @media (max-width: 620px) { .cards { grid-template-columns: 1fr; } }

  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 20px 18px 16px;
    position: relative;
    overflow: hidden;
  }
  .card::after {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 3px;
    border-radius: 10px 10px 0 0;
  }
  .card.pass::after { background: var(--pass); }
  .card.fail::after { background: var(--fail); }

  .card .card-label {
    font-size: 10px;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 8px;
  }
  .card .card-value {
    font-family: var(--display);
    font-size: 1.6rem;
    font-weight: 800;
    color: #e8f0ff;
    line-height: 1;
    margin-bottom: 4px;
  }
  .card.fail .card-value { color: var(--fail); }

  .card .card-req {
    font-size: 11px;
    color: var(--muted);
    margin-bottom: 10px;
  }
  .meter-track {
    background: var(--border);
    border-radius: 4px;
    height: 4px;
    overflow: hidden;
    margin-bottom: 12px;
  }
  .meter-fill { height: 100%; border-radius: 4px; }
  .pass .meter-fill  { background: var(--pass); }
  .fail .meter-fill  { background: var(--fail); }

  .tool-table {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    margin-bottom: 32px;
  }
  .tool-row {
    display: grid;
    grid-template-columns: 170px 1fr auto;
    align-items: center;
    padding: 14px 20px;
    border-bottom: 1px solid var(--border);
    gap: 14px;
  }
  .tool-row:last-child { border-bottom: none; }
  .tool-name { font-weight: 600; font-size: 13px; }
  .tool-detail { color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

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
  .badge.pass { background: var(--pass-bg); color: var(--pass); border: 1px solid var(--pass); }
  .badge.fail { background: var(--fail-bg); color: var(--fail); border: 1px solid var(--fail); }
  .badge.warn { background: var(--warn-bg); color: var(--warn); border: 1px solid var(--warn); }
  .badge.ok   { background: var(--ok-bg);   color: var(--ok);   border: 1px solid var(--ok);  }

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
    gap: 0;
  }
  @media (max-width: 620px) { .os-info-grid { grid-template-columns: 1fr; } }
  .os-cell {
    padding: 16px 20px;
    border-right: 1px solid var(--border);
    border-bottom: 1px solid var(--border);
  }
  .os-cell:nth-child(3n) { border-right: none; }
  .os-cell:nth-last-child(-n+3) { border-bottom: none; }
  @media (max-width: 620px) {
    .os-cell { border-right: none; }
    .os-cell:last-child { border-bottom: none; }
  }
  .os-cell .os-key {
    font-size: 10px;
    letter-spacing: 0.13em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 4px;
  }
  .os-cell .os-val {
    font-size: 13px;
    font-weight: 600;
    color: #e8f0ff;
    word-break: break-word;
  }

  .install-steps {
    background: #0d1117;
    border-top: 1px solid var(--border);
    padding: 14px 20px 14px 52px;
    display: none;
  }
  .install-steps.open { display: block; }
  .install-steps pre {
    font-family: var(--mono);
    font-size: 12px;
    color: #7dd3fc;
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.8;
    margin: 0;
  }
  .install-toggle {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    margin-top: 6px;
    font-size: 11px;
    color: var(--warn);
    cursor: pointer;
    background: none;
    border: 1px solid var(--warn);
    border-radius: 4px;
    padding: 2px 8px;
    font-family: var(--mono);
    letter-spacing: 0.05em;
    transition: background 0.15s;
  }
  .install-toggle:hover { background: var(--warn-bg); }
  .tool-cell-wrap { display: flex; flex-direction: column; }

  footer {
    text-align: center;
    color: var(--muted);
    font-size: 11px;
    letter-spacing: 0.08em;
    border-top: 1px solid var(--border);
    padding-top: 20px;
  }
</style>
</head>
<body>
<div class="wrapper">

  <header>
    <div class="pre-label">// system pre-flight check</div>
    <h1>System Requirements Report</h1>
    <div class="meta">Generated: ${DATE_HUMAN}</div>
    <div class="meta">Host: ${HOST_NAME} &nbsp;|&nbsp; Kernel: ${KERNEL_VER} &nbsp;|&nbsp; Arch: ${OS_ARCH}</div>
  </header>

  <div class="verdict ${overall_class}">
    <span class="icon">${overall_icon}</span>
    OVERALL: ${OVERALL} &mdash; ${overall_msg}
  </div>

  <div class="section-title">Operating System</div>
  <div class="os-info">
    <div class="os-info-grid">
      <div class="os-cell"><div class="os-key">OS Name</div><div class="os-val">${OS_NAME}</div></div>
      <div class="os-cell"><div class="os-key">Version</div><div class="os-val">${OS_VERSION}</div></div>
      <div class="os-cell"><div class="os-key">Codename</div><div class="os-val">${OS_CODENAME}</div></div>
      <div class="os-cell"><div class="os-key">Distribution ID</div><div class="os-val">${OS_ID}</div></div>
      <div class="os-cell"><div class="os-key">Kernel</div><div class="os-val">${KERNEL_VER}</div></div>
      <div class="os-cell"><div class="os-key">Architecture</div><div class="os-val">${OS_ARCH}</div></div>
    </div>
  </div>

  <div class="section-title">Requested Requirements</div>
  <div class="req-box">
    <div class="req-item"><div class="req-key">CPU Cores</div><div class="req-val">${REQ_CPU} cores</div></div>
    <div class="req-item"><div class="req-key">RAM</div><div class="req-val">${REQ_RAM} GB <span style="font-size:11px;color:var(--muted)">(±${TOLERANCE}GB tolerance)</span></div></div>
    <div class="req-item"><div class="req-key">Free Disk Space</div><div class="req-val">${REQ_STORAGE} GB <span style="font-size:11px;color:var(--muted)">(±${TOLERANCE}GB tolerance)</span></div></div>
    <div class="req-item"><div class="req-key">Storage Mount Point</div><div class="req-val">${MOUNT_POINT}</div></div>
  </div>

  <div class="section-title">Resource Checks</div>
  <div class="cards">

    <div class="card ${cpu_card_cls}">
      <div class="card-label">CPU Cores</div>
      <div class="card-value">${SYS_CPU}</div>
      <div class="card-req">Required: ${REQ_CPU} cores</div>
      <div class="meter-track"><div class="meter-fill" style="width:${cpu_pct}%"></div></div>
      ${cpu_badge}
    </div>

    <div class="card ${ram_card_cls}">
      <div class="card-label">RAM</div>
      <div class="card-value">${SYS_RAM} GB</div>
      <div class="card-req">Required: ${REQ_RAM} GB &nbsp;&middot;&nbsp; Effective min: ${RAM_EFFECTIVE} GB (±${TOLERANCE}GB)${RAM_NOTE}</div>
      <div class="meter-track"><div class="meter-fill" style="width:${ram_pct}%"></div></div>
      ${ram_badge}
    </div>

    <div class="card ${stor_card_cls}">
      <div class="card-label">Free Disk &mdash; ${MOUNT_POINT}</div>
      <div class="card-value">${SYS_STORAGE} GB</div>
      <div class="card-req">Required: ${REQ_STORAGE} GB &nbsp;&middot;&nbsp; Effective min: ${STOR_EFFECTIVE} GB (±${TOLERANCE}GB)${STOR_NOTE}</div>
      <div class="meter-track"><div class="meter-fill" style="width:${stor_pct}%"></div></div>
      ${stor_badge}
    </div>

  </div>

  <div class="section-title">Software &amp; Security Checks</div>
  <div class="tool-table">
    <div class="tool-row">
      <div class="tool-name">&#128274; Firewall</div>
      <div class="tool-detail">${FW_DETAIL}</div>
      <div>${fw_badge}</div>
    </div>

    <div class="tool-row" style="align-items:flex-start; flex-wrap:wrap;">
      <div class="tool-name" style="padding-top:2px;">&#128051; Docker</div>
      <div class="tool-cell-wrap">
        <div class="tool-detail">${DOCKER_VERSION:-not installed}</div>
        $(if $DOCKER_WARN; then echo '<button class="install-toggle" onclick="toggleInstall(this, '"'"'docker-steps'"'"')">&#9660; show install steps</button>'; fi)
      </div>
      <div>${docker_badge}</div>
    </div>
    $(if $DOCKER_WARN; then
      DOCKER_HTML=$(echo "$DOCKER_INSTALL_STEPS" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      echo "<div class=\"install-steps\" id=\"docker-steps\"><pre>${DOCKER_HTML}</pre></div>"
    fi)

    <div class="tool-row" style="align-items:flex-start; flex-wrap:wrap;">
      <div class="tool-name" style="padding-top:2px;">&#128025; Docker Compose</div>
      <div class="tool-cell-wrap">
        <div class="tool-detail">${COMPOSE_VERSION:-not installed}</div>
        $(if $COMPOSE_WARN; then echo '<button class="install-toggle" onclick="toggleInstall(this, '"'"'compose-steps'"'"')">&#9660; show install steps</button>'; fi)
      </div>
      <div>${compose_badge}</div>
    </div>
    $(if $COMPOSE_WARN; then
      COMPOSE_HTML=$(echo "$COMPOSE_INSTALL_STEPS" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      echo "<div class=\"install-steps\" id=\"compose-steps\"><pre>${COMPOSE_HTML}</pre></div>"
    fi)

    <div class="tool-row" style="align-items:flex-start; flex-wrap:wrap;">
      <div class="tool-name" style="padding-top:2px;">&#127760; Curl</div>
      <div class="tool-cell-wrap">
        <div class="tool-detail">${CURL_VERSION:-not found}</div>
        $(if $CURL_WARN; then echo '<button class="install-toggle" onclick="toggleInstall(this, '"'"'curl-steps'"'"')">&#9660; show install steps</button>'; fi)
      </div>
      <div>${curl_badge}</div>
    </div>
    $(if $CURL_WARN; then
      CURL_HTML=$(echo "$CURL_INSTALL_STEPS" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      echo "<div class=\"install-steps\" id=\"curl-steps\"><pre>${CURL_HTML}</pre></div>"
    fi)

  </div>

  <script>
  function toggleInstall(btn, id) {
    var el = document.getElementById(id);
    if (!el) return;
    var open = el.classList.toggle('open');
    btn.innerHTML = open ? '&#9650; hide install steps' : '&#9660; show install steps';
  }
  </script>

  <div class="section-title">Legend</div>
  <div class="legend">
    <div class="legend-row"><span class="badge pass">PASS / OK / FOUND</span> Requirement met or tool is available</div>
    <div class="legend-row"><span class="badge fail">FAIL</span> CPU / RAM / Storage is below the required value &mdash; action required</div>
    <div class="legend-row"><span class="badge warn">WARNING / MISSING</span> Firewall is active (may block services) or required tool is not installed</div>
  </div>

  <footer>
    system_check.sh &nbsp;&middot;&nbsp; Report: ${REPORT_FILE}
  </footer>

</div>
</body>
</html>
HTMLEOF

echo -e "${CYAN}  HTML report saved:${RESET} ${REPORT_FILE}\n"