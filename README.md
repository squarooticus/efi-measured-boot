# TPM2 Measured Boot for UEFI Systems

Currently, a disorganized set of files and one submodule that need to be assembled and initialized in a specific manner on a machine with a LUKS-encrypted root filesystem and a UEFI firmware. The result of proper installation is a TPM2-enabled measured Linux boot with non-interactive mount of an encrypted root volume.

The primary goal of this project is to prevent offline tampering of the boot chain through the point at which the boot is handed off to init on the root filesystem. Additional goals include:

- Boot Linux directly from UEFI firmware without an intermediate boot loader (e.g., GRUB).
- Support LUKS-encrypted root filesystems.
- Under normal operation, require no interaction to boot into a properly-installed kernel.
- Prevent downgrade attacks involving previously-authorized kernel blobs with known vulnerabilities.
- Always fall back to console passphrase entry, even under a broad range of unexpected failure scenarios ("unknown unknowns").

Eventually, I intend to turn this into an official Debian package. Before that, however, I will cough up a Makefile that will allow users to directly install and configure it in a safe manner. I won't be able to automate encryption of the root volume or the creation of an EFI system partition, however, so you'll need to handle that some other way, regardless. If you get grub-efi working and set up GRUB encrypted boot (`GRUB_ENABLE_CRYPTODISK=y` in `/etc/defaults/grub`), you'll be ready to install this. (Note, however, that this system bypasses GRUB and boots Linux directly as a UEFI application.)

This project is heavily dependent on the work of Mantas Mikulėnas to parse the UEFI boot log in order to [predict future PCR values](https://github.com/grawity/tpm_futurepcr).

## Licensing

This work is licensed under the MIT License. See the LICENSE file for more information.
