# Measured Boot for TPM 2.0-enabled UEFI Systems

The primary goal of this project is to prevent unauthorized boot chains (from BIOS up to launching init) from accessing the data on an encrypted root partition while allowing authorized boot chains to mount that partition at boot time without user interaction (such as passphrase entry). Additional goals include:

- Boot Linux directly from UEFI firmware without an intermediate boot loader (e.g., GRUB).
- Support root filesystems hosted on dm-crypt devices with LUKS2 metadata.
- Prevent downgrade attacks involving previously-authorized kernel blobs with known vulnerabilities.
- Always fall back to console passphrase entry, even under a broad range of unexpected failure scenarios ("unknown unknowns").

## Status

Presently, a bunch of scripts and a Makefile that, when used on a machine with a LUKS-encrypted root filesystem and a UEFI firmware, will result in a TPM 2.0-enabled measured Linux boot supporting non-interactive mount of the encrypted root volume.

The installation procedure requires that your system be prepared in a few specific ways:

* The root partition must be hosted on a dm-crypt device with LUKS2 metadata (version 2 required for token support). This root partition must also include /boot.
* You must have a compliant EFI System Partition mounted under /boot/efi with sufficient space to allow the installation of two kernel blobs (each roughly the size of the kernel and initrd combined: for future growth in kernel sizes, target 500M or more).

The easiest way to meet most of these requirements is to get grub-efi 2.06 working with GRUB encrypted boot (`GRUB_ENABLE_CRYPTODISK=y` in `/etc/defaults/grub`) and verify that you can boot using the GRUB UEFI entry by entering the root passphrase when GRUB first starts up. While the result of installing this measured boot solution bypasses GRUB, I recommend retaining a working grub-efi install for recovery and for debugging when the ability to change the kernel command line is required.

**Note:** the build of grub 2.06 currently in Debian's unstable repository does not have LUKS2 support built in, which means you'll need to build your own with that support; and it appears to break `GRUB_ENABLE_CRYPTODISK=y`, for which the easiest resolution is to create a boot entry pointing at the monolithic EFI image copied manually to the EFI system partition.

## Installation

```
sudo make install
```

Then follow further instructions from the install.

## Future Work

Eventually, I intend to turn this into an official Debian package, though manual steps to prep the system will likely still be required.

## Acknowledgements

This project is heavily dependent on the work of Mantas Mikulėnas to parse the UEFI boot log in order to [predict future PCR values](https://github.com/grawity/tpm_futurepcr).

## Licensing

This work is licensed under the MIT License. See the LICENSE file for more information.
