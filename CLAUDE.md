# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

This is a Debian-focused system for TPM 2.0-measured EFI boot with automatic, non-interactive LUKS2 root unlock. The system:

1. Builds monolithic EFI kernel blobs (kernel + initrd + cmdline bundled via `objcopy` into a systemd-boot EFI stub)
2. Uses `pcr-oracle` (a git submodule) to predict future TPM PCR values based on the current boot's event log
3. Seals a LUKS2 passphrase to predicted PCR values + a monotonic anti-downgrade NV counter using `tpm2-tools`
4. Stores the sealed blob as a custom LUKS2 token (`"type": "emboot"`) in the LUKS header
5. At boot, `emboot_unseal.sh` (a cryptsetup `keyscript`) tries to unseal and pass the passphrase to the kernel; falls back to interactive passphrase entry on any failure

## Installation flow

Three-step process driven by `Makefile`:

```
sudo make install   # runs safety_checks + prep_emboot: installs hooks/scripts, builds pcr-oracle, modifies /etc/crypttab
                    # inspect/edit /etc/efi-measured-boot/config, then:
sudo make step2     # runs prep_emboot_2: provisions TPM counter, generates LUKS key, rebuilds initrd, sets next-boot EFI entry
                    # reboot and enter LUKS passphrase; if boot succeeds, then:
sudo make step3     # runs update-emboot -s: seals LUKS passphrase to PCR predictions, creates LUKS tokens
```

## Key scripts and their roles

- **`functions`** — POSIX sh library (sourced in initramfs context). Contains logging, TPM wrappers (`seal_data`, `unseal_data`), LUKS token management, and EFI loader creation (`create_loader`).
- **`bash_functions`** — Bash library (sourced in normal root context). Extends `functions` with bash-specific utilities: `compare_versions`, `provision_counter`, LUKS metadata caching, EFI variable management, and the high-level operations (`install_loaders`, `update_tokens`, `seal_and_create_token`).
- **`update-emboot`** — Main entry point for ongoing maintenance. Called by kernel hooks on install/remove.
- **`emboot_unseal.sh`** — Initramfs keyscript. Runs as POSIX sh inside the initrd; sources `functions` (not `bash_functions`).
- **`safety_checks`** — Pre-install validation: checks arch, root, packages, LUKS2, TPM availability, and pcr-oracle submodule.
- **`prep_emboot`** — Step 1 installer: copies files to `/usr/local/share/efi-measured-boot`, installs hooks, builds `pcr-oracle`, writes `/etc/efi-measured-boot/config`.
- **`prep_emboot_2`** — Step 2 installer: provisions TPM NV counter, adds LUKS key, rebuilds initrd.

## Configuration

Runtime config lives in `/etc/efi-measured-boot/config` (shell variables sourced by all scripts):

| Variable | Default / Example | Purpose |
|---|---|---|
| `EFI_MOUNT` | `/boot/efi` | ESP mount point |
| `OS_SHORT_NAME` | `debian` | Used in EFI loader path: `\EFI\<name>\emboot.efi` |
| `COUNTER_HANDLE` | `0x1926001` | TPM NV index for monotonic counter |
| `SEAL_PCRS` | `0,2,4` | PCRs to include in seal policy |
| `LUKS_KEY` | `/etc/keys/root-emboot.key` | Path to the LUKS key file |
| `KERNEL_PARAMS` | `"ro add_efi_memmap"` | Extra kernel command line parameters |
| `UPDATE_BOOT_ORDER` | `y` | Whether to reorder EFI boot entries |
| `APPDIR` | `/usr/local/share/efi-measured-boot` | Where `functions` and `emboot_unseal.sh` are installed |
| `VERBOSE` / `EMBOOT_VERBOSE` | (unset) | Verbosity: 0=normal, 3=info, 4=debug, 5=debug+detail |

## EFI loader management

Two EFI loader files are maintained:
- `$EFI_MOUNT/EFI/$OS_SHORT_NAME/emboot.efi` — newest kernel
- `$EFI_MOUNT/EFI/$OS_SHORT_NAME/emboot_old.efi` — second-newest kernel

Each loader is a PE binary (`objcopy` embedding `.osrel`, `.krel`, `.cmdline`, `.initrd`, `.linux` sections into the systemd EFI stub). The `.krel` section stores the kernel release string and is used to match loaders to LUKS tokens.

## Kernel/initrd hooks

`kernel-hooks/efi-measured-boot` is installed as:
- `/etc/kernel/postinst.d/zz-efi-measured-boot` — runs `update-emboot` on kernel install
- `/etc/kernel/postrm.d/zz-efi-measured-boot` — runs `update-emboot -r -k <krel>` + increments counter on kernel removal
- `/etc/initramfs/post-update.d/zz-efi-measured-boot` — runs `update-emboot` when initrd changes

`initramfs-hooks/efi-measured-boot` is installed as `/etc/initramfs-tools/hooks/efi-measured-boot` and copies required binaries (`tpm2_*`, `jq`) and config into the initramfs.

## Logging system

Log levels (defined in `functions`): `LL_ALWAYS=0`, `LL_FATAL=0`, `LL_ERROR=1`, `LL_WARN=2`, `LL_INFO=3`, `LL_DEBUG=4`, `LL_DEBUG_DETAIL=5`.

Functions: `log`, `log_fatal`, `log_error`, `log_warn`, `log_info`, `log_debug`. All output goes to stderr. Topic tags (e.g., `-t tpm`, `-t luks,efi`) are printed as a left-aligned prefix. `log_command` / `lc_tpm` / `lc_luks` / `lc_efi` / `lc_core` / `lc_misc` wrap external command execution with logging.

## pcr-oracle submodule

`pcr-oracle/` is a git submodule (cloned from `../pcr-oracle.git`). It is a C binary that predicts future PCR values by replaying the TPM event log up to a specified stop-event and extending with measurements for the new EFI loader. Built in-tree during `prep_emboot` via:

```sh
cd pcr-oracle && ./configure && make && make install DESTDIR=/usr/local
```

Installed to `/usr/local/bin/pcr-oracle`. The submodule must be initialized (`git submodule update --init`) before running safety checks or installation.

## update-emboot usage

```
update-emboot [options]

# Default: rebuild loaders and reseal tokens
sudo update-emboot

# Reseal tokens only (don't touch EFI loaders)
sudo update-emboot -s

# Update loaders only (don't seal)
sudo update-emboot -S

# Reseal for a specific kernel release
sudo update-emboot -s -k 6.1.0-26-amd64

# Remove token for a specific release (e.g., after removing a kernel)
sudo update-emboot -r -k 6.1.0-25-amd64

# Increment monotonic counter (invalidates all existing sealed tokens)
sudo update-emboot -i

# Verbose output
sudo update-emboot -v        # level 3 (info)
sudo update-emboot -vv       # level 4 (debug)
sudo update-emboot -vvv      # level 5 (debug+detail)

# Dry run (print commands without executing)
sudo update-emboot -n
```

## System requirements

x86_64 only. Requires: `cryptsetup-initramfs`, `initramfs-tools`, `tpm2-tools`, `efibootmgr`, `jq`, `gdisk` (`sgdisk`), `objcopy`, `gawk`. Dev packages for `json-c` and `tss2-esys` are needed to build `pcr-oracle`. LUKS2 root device with at least one PBKDF2-hashed passphrase is required (for GRUB recovery compatibility).
