# Linux Ops Toolkit

A collection of Linux shell scripts for system administration, pre-flight checks, and operational readiness validation. Each script is self-contained, well-documented, and produces both a terminal summary and a standalone HTML report.

---

## Purpose

Managing and validating Linux infrastructure manually is time-consuming and error-prone. This repository provides a growing set of ready-to-run Bash scripts that automate common operational checks — covering system resources, software dependencies, security posture, and more.

Each script is designed to be:

- **Portable** — runs on any major Linux distro with no external dependencies
- **Readable** — clear terminal output with colour-coded results at a glance
- **Reportable** — generates a timestamped HTML report on every run for audit trails
- **Actionable** — where issues are found, remediation steps are provided inline

---

## Repository Structure

```
.
├── README.md                          # This file — repo overview
│
├── system_check/                      # Pre-flight system requirements checker
│   ├── system_check.sh
│   ├── README.md
│   └── system_sample_reports/
│       ├── report_2026-04-08_14-32-01.html
│       └── terminal_output.png
│
└── lvm_extend/                        # Interactive LVM volume extension utility
    ├── lvm_extend.sh
    ├── README.md
    └── system_sample_reports/
        ├── lvm_report_server01_2026-04-08.html
        └── terminal_output.png
```

Each folder contains:

- The shell script itself
- A `README.md` with full usage documentation
- A `system_sample_reports/` folder with a sample HTML report and terminal screenshot so you can see what the output looks like before running it

---

## Scripts

### `system-check/` — Pre-flight System Requirements Checker

Validates a Linux host against a set of minimum requirements before deploying software or infrastructure. Pass your required CPU, RAM, and disk values as inline arguments and the script compares them against the actual system specs.

**Checks performed:**

- CPU core count
- Available RAM
- Free disk space (configurable mount point)
- Operating system details (distro, version, kernel, architecture)
- Firewall status (ufw / firewalld / iptables)
- Docker availability and version
- Docker Compose availability and version
- Curl availability and version

**Key features:**

- ±2 GB tolerance on RAM and storage — minor shortfalls don't fail the run
- Auto-detects package manager and prints distro-specific install commands for any missing package
- Saves a timestamped HTML report with expandable install steps on every run

```bash
chmod +x system_check/system_check.sh
./system_check/system_check.sh --cpu 4 --ram 16 --storage 100
./system_check/system_check.sh --cpu 4 --ram 16 --storage 500 --mount /data
```

See [`system_check/README.md`](system_check/README.md) for full documentation.

---

### `lvm_extend/` — Interactive LVM Volume Extension Utility

An interactive guided tool for extending LVM logical volumes on Linux. Rather than requiring you to know and chain LVM commands manually, the script audits your full storage layout, walks you through selecting the volume group and logical volume to extend, handles missing PV recovery if the VG is degraded, runs the extension, and resizes the filesystem — all in one session. Every step is captured in a styled HTML report saved to `./lvm_reports/`.

**What it covers:**

- Filesystem usage with colour-coded warnings (≥70% orange, ≥90% red)
- Block device tree, physical volumes, volume groups, logical volumes, and fstab
- New disk / partition / VM resize support before extending (`pvcreate`, `growpart`, `pvresize`)
- Missing PV detection with guided recovery options before any extension proceeds
- LV extension using all free space or a specific size
- Automatic filesystem resize for ext2/ext3/ext4 (`resize2fs`) and xfs (`xfs_growfs`)
- Pre- and post-extension storage snapshots in the HTML report
- Audit-only mode — if extension is skipped, a storage snapshot report is still saved

```bash
chmod +x lvm_extend/lvm_extend.sh
sudo ./lvm_extend/lvm_extend.sh
```

> Requires root. No arguments needed — fully interactive.

See [`lvm_extend/README.md`](lvm_extend/README.md) for full documentation.

---

## General Usage Pattern

All scripts in this repo follow the same conventions:

```bash
# 1. Make executable
chmod +x <folder>/<script>.sh

# 2. Run (with arguments if required, or interactively)
./<folder>/<script>.sh --option value   # system_check
sudo ./<folder>/<script>.sh             # lvm_extend (root required)

# 3. Review terminal output (colour-coded)
# 4. Open the HTML report saved to ./<folder>/<script>_reports/
```

---

## Output Format

Every script produces two outputs:

**Terminal** — colour-coded results printed immediately:

| Tag | Colour | Meaning |
|-----|--------|---------|
| `[PASS]` / `[ OK ]` | 🟢 Green | Check passed or step completed successfully |
| `[FAIL]` / `[ERROR]` | 🔴 Red | Requirement not met or fatal error |
| `[WARN]` | 🟡 Orange | Advisory — action may be needed |
| `[STEP]` | 🔵 Blue | Command being executed (lvm_extend) |
| `[ OS ]` | 🔵 Cyan | Informational OS detail |

**HTML Report** — saved to a timestamped file in the script's report folder on every run. Each run creates a new file so you retain a full history. Reports share the same dark-themed design — OS panel, colour-coded sections, badge-tagged results, and a legend.

| Script | Report location |
|--------|----------------|
| `system_check.sh` | `./system_reports/report_<timestamp>.html` |
| `lvm_extend.sh` | `./lvm_reports/lvm_report_<hostname>_<timestamp>.html` |

---

## Requirements

- Bash 4.0+
- Standard Linux coreutils (`awk`, `df`, `grep`, `uname`, `hostname`, `nproc`)
- No third-party tools or package installs required to run the system-check script
- `lvm2` package required for `lvm_extend.sh` (see its README for per-distro install commands)

Tested on Ubuntu 20.04+, Debian 11+, RHEL/CentOS 8+, Rocky Linux 8+, AlmaLinux 8+, Fedora 36+, Amazon Linux 2, Arch Linux, Alpine Linux.

---

## Contributing

Pull requests are welcome. When adding a new script please follow the existing conventions:

- One folder per script
- A `README.md` inside the folder with usage, parameters, and output documentation
- A `system_sample_reports/` folder with a sample HTML report and terminal screenshot
- Inline `--help` / `-h` flag support for argument-driven scripts
- Fully interactive scripts should validate root/permissions at the top and exit cleanly with a clear message
- Compatible with `bash -n` syntax checking (no bashisms beyond Bash 4)
- HTML report must use the shared dark-theme CSS design system (fonts, colour variables, OS panel, badge styles) for consistency across the toolkit

---

## License

MIT — free to use, modify, and distribute.
