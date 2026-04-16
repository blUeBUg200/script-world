# lvm_extend.sh

An interactive LVM (Logical Volume Manager) Volume Extension Utility for Linux. The script audits your current storage layout, guides you step-by-step through extending a logical volume, handles missing PV recovery, resizes the filesystem automatically, and saves a full timestamped report of every action taken.

> **Requires root** — run with `sudo`.

---

## Features

- **Full storage audit** — captures filesystem usage, block devices, physical volumes, volume groups, logical volumes, and fstab in one report
- **Colour-coded filesystem warnings** — highlights partitions at ≥70% usage (orange) and ≥90% usage (red)
- **Interactive guided extension** — step-by-step prompts to select VG, LV, and size without needing to remember LVM commands
- **Missing PV detection and recovery** — detects degraded volume groups and offers guided remediation before proceeding
- **Flexible sizing** — extend using all available free space, or specify an exact size (e.g. `50G`)
- **Auto filesystem resize** — detects `ext2`/`ext3`/`ext4` and `xfs` and runs the correct resize tool automatically
- **New disk support** — optionally add a new physical volume to a volume group before extending
- **Full audit trail** — every command and its output is saved to a timestamped HTML report in `./lvm_reports/`

---

## Requirements

- Bash 4.0+
- Root / sudo access
- LVM2 tools: `lvm2` package (`pvs`, `vgs`, `lvs`, `pvdisplay`, `vgdisplay`, `lvdisplay`, `lvextend`, `vgextend`, `vgreduce`)
- Standard utilities: `lsblk`, `df`, `blkid`, `findmnt`
- Filesystem resize tools (installed alongside the filesystem):
  - `resize2fs` — for ext2/ext3/ext4
  - `xfs_growfs` — for xfs

### Install LVM2 if missing

```bash
# Debian / Ubuntu
sudo apt-get install -y lvm2

# RHEL / CentOS / Rocky / AlmaLinux
sudo yum install -y lvm2

# Fedora
sudo dnf install -y lvm2

# Arch Linux
sudo pacman -S lvm2

# Alpine
sudo apk add lvm2
```

---

## Usage

```bash
chmod +x lvm_extend.sh
sudo ./lvm_extend.sh
```

The script requires no arguments — it is fully interactive.

---

## Walkthrough

Once launched, the script runs through the following sections automatically and then enters interactive mode:

### Sections 1–6 (Automatic — read-only audit)

| Section | What it shows |
|---------|---------------|
| 1. Filesystem & Mount Points | `df -h` output with colour-coded usage warnings |
| 2. Block Devices | `lsblk` tree of all block devices |
| 3. Physical Volumes | PV summary table + detailed `pvdisplay` |
| 4. Volume Groups | VG summary table (highlights VGs with <1 GB free in yellow) + `vgdisplay` |
| 5. Logical Volumes | LV summary table + `lvdisplay` |
| 6. /etc/fstab | Current persistent mount configuration |

### Section 7 (Interactive — guided extension)

The script first asks whether to proceed. If yes, it walks you through five prompts:

**7a — Select source of additional space**
```
[1] New physical disk         (e.g. /dev/sdb)
[2] New partition on disk     (e.g. /dev/sda3)
[3] VM/cloud disk was resized (growpart + pvresize)
[4] VG already has free space (skip to LV extend)
```
Options 1 and 2 handle existing disk signatures safely — if a signature is detected you are prompted to wipe it before `pvcreate` runs. A force flag (`-ff`) is offered as a fallback if `pvcreate` fails.

**7b — Select Volume Group + missing PV check**
```
Available Volume Groups:
  ubuntu-vg   18.00g total   0.00g free
  data-vg    500.00g total  120.50g free

Enter VG name (e.g. ubuntu-vg):
```
Immediately after selection, the VG is checked for missing Physical Volumes. If any are found, you are offered three recovery options before the extension can proceed:
1. Remove the missing PV record (`vgreduce --removemissing --force`)
2. Restore a replaced disk into the VG (`vgextend --restoremissing`)
3. Abort and fix manually

**7c — Select a Logical Volume**
```
Logical Volumes in 'ubuntu-vg':
  /dev/ubuntu-vg/ubuntu-lv   18.00g

Enter LV path (e.g. /dev/ubuntu-vg/ubuntu-lv):
```

**7d — Choose how much space to add**
```
[1] Use ALL available free space in VG
[2] Specify exact amount (e.g. 50G)
```

**7e — Filesystem resize (automatic)**
The script detects the filesystem type and runs the correct command:

| Filesystem | Command run |
|------------|-------------|
| ext2 / ext3 / ext4 | `resize2fs <lv_path>` |
| xfs | `xfs_growfs <mountpoint>` |
| Other | Warning printed with manual instructions |

### Section 8 (Automatic — post-extension snapshot)

After the extension, the script re-runs `df`, `pvs`, `vgs`, `lvs`, and `lsblk` so you can immediately confirm the new sizes — all captured in the report.

---

## Output

### Terminal

Each line is tagged with a colour-coded prefix:

| Tag | Colour | Meaning |
|-----|--------|---------|
| `[INFO]` | 🟢 Green | Informational message |
| `[ OK ]` | 🟢 Green | Step completed successfully |
| `[STEP]` | 🔵 Blue | LVM command being executed |
| `[WARN]` | 🟡 Orange | Advisory — low space, missing PV, unknown filesystem |
| `[ERROR]` | 🔴 Red | Fatal error — script will exit |
| `[ OS ]` | 🔵 Cyan | Informational OS detail |

### HTML Report

Every run saves a styled HTML report to:

```
./lvm_reports/lvm_report_<hostname>_<YYYY-MM-DD_HH-MM-SS>.html
```

The report includes:
- Overall result verdict banner (Complete / Skipped / Aborted)
- Operating system details panel
- All six audit sections rendered as syntax-highlighted code panels (pre-extension state)
- Extension actions table — each step with a name, detail, and colour-coded badge
- Post-extension storage state (df, pvs, vgs, lvs after changes)
- Legend for all badge types

Reports are never overwritten — each run creates a new timestamped file, giving you a full audit trail.

---

## Safety Notes

- The script will **not proceed** with extension if the selected VG has unresolved missing PVs — it forces you to fix the VG health first
- All destructive operations (`vgreduce --removemissing --force`) require an explicit `y` confirmation before executing
- The script exits immediately (`set -euo pipefail`) on any unexpected error — partial operations are not silently swallowed
- **Always review Sections 1–6** before confirming the extension — they tell you exactly what space is available and where

---

## File Structure

```
.
├── lvm_extend/                            # Root folder
│   ├── lvm_extend.sh                      # Main script
│   ├── README.md                          # This file
│   └── system_sample_reports/             # Sample outputs for reference
│       ├── lvm_report_server01_2026-04-08.html
│       └── terminal_output.png
```

> Live reports are generated in `./lvm_reports/` relative to wherever the script is run from. The directory is created automatically on first run.

---

## Notes

- The script must be run as root (`sudo`) — it will exit immediately if the effective user ID is not 0
- XFS filesystems must be mounted before they can be grown — `xfs_growfs` operates on the mount point, not the device
- If your filesystem type is not ext4 or xfs, the LV will still be extended but you will need to resize the filesystem manually
- The `./lvm_reports/` directory is created automatically on first run in the current working directory
- If the extension is skipped at the prompt, an audit-only HTML report is still saved — useful for capturing a storage snapshot without making any changes
