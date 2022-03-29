# Measured Boot for TPM 2.0-enabled UEFI Systems

The primary goal of this project is to prevent offline tampering of the boot chain through the point at which the boot is handed off to init on the root filesystem. Additional goals include:

- Boot Linux directly from UEFI firmware without an intermediate boot loader (e.g., GRUB).
- Support LUKS-encrypted root filesystems.
- Under normal operation, require no interaction to mount the encrypted root filesystem at boot time.
- Prevent downgrade attacks involving previously-authorized kernel blobs with known vulnerabilities.
- Always fall back to console passphrase entry, even under a broad range of unexpected failure scenarios ("unknown unknowns").

## Status

Presently, a bunch of scripts and a Makefile that, when used on a machine with a LUKS-encrypted root filesystem and a UEFI firmware, will result in a TPM 2.0-enabled measured Linux boot supporting non-interactive mount of the encrypted root volume.

The installation procedure requires that your system be prepared in a few specific ways:

* The root partition must be encrypted with a LUKS header. This root partition must also include /boot.
* You must have a compliant EFI System Partition mounted under /boot/efi with sufficient space to allow the installation of two kernel blobs (each roughly the size of the kernel and initrd combined).

The easiest way to meet most of these requirements is to get grub-efi working with GRUB encrypted boot (`GRUB_ENABLE_CRYPTODISK=y` in `/etc/defaults/grub`) and verify that you can boot using the GRUB UEFI entry by entering the root passphrase when GRUB first starts up. While the result of installing this measured boot solution bypasses GRUB, I recommend retaining a working grub-efi install for recovery and for debugging when the ability to change the kernel command line is required.

## Future Work

Eventually, I intend to turn this into an official Debian package, though manual steps to prep the system will likely still be required.

## Acknowledgements

This project is heavily dependent on the work of Mantas Mikulėnas to parse the UEFI boot log in order to [predict future PCR values](https://github.com/grawity/tpm_futurepcr).

## Licensing

This work is licensed under the MIT License. See the LICENSE file for more information.
