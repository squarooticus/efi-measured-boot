# Measured Boot for TPM 2.0-enabled UEFI Debian Systems

The primary goal of this project is to prevent unauthorized boot chains (from BIOS up to launching init) from accessing the data on an encrypted root device while allowing authorized boot chains to mount that device at boot time without user interaction (such as passphrase entry). Specific functional requirements include:

- Boot Linux directly from UEFI firmware without an intermediate boot loader (e.g., GRUB).
- Support root filesystems hosted on dm-crypt devices with LUKS2 metadata.
- Store a LUKS passphrase for the root device, sealed to a set of PCRs associated with an approved system state, in a LUKS2 token on the encrypted device.
- Prevent downgrade attacks involving previously-authorized kernel blobs with known vulnerabilities.
- Always fall back to console passphrase entry, even under a broad range of unexpected failure scenarios ("unknown unknowns").
- Automatically update EFI loaders and the sealed LUKS passphrase as kernels are installed/removed and initrd images are updated.

## Status

Presently, a bunch of scripts and a Makefile that, when used on a machine with a LUKS-encrypted root filesystem and a UEFI firmware, will result in a TPM 2.0-enabled measured Linux boot supporting non-interactive mount of the encrypted root volume.

## Preparation

The installation procedure requires that your system be prepared in a few specific ways:

* Your system setup must be configured to boot Linux via an EFI application (e.g., using grub-efi) rather than chaining to a legacy MBR boot loader (like grub-pc).
* You will almost certainly need to disable legacy BIOS boot support (i.e., the CSM or "compatibility support module") as TPM 2.0 interfaces are typically disabled unless your system setup is configured in UEFI-only boot mode.
* The TPM must be enabled in the firmware settings: this can either be discrete (if your motherboard has a separate TPM 2.0 chip) or PTT/fTPM (if you are using the firmware TPM provided by your CPU).
* Secure boot must be disabled, as this software does not currently support signing the resulting EFI loaders.
* The root device must be hosted on a dm-crypt device with LUKS2 metadata (version 2 required for token support).
* `/boot` must not be a separate partition, but instead must be hosted on the encrypted root device. (This is mainly a safety measure to prevent any unintended future use of unprotected boot chains.)
* You must have a compliant EFI System Partition mounted under `/boot/efi` with sufficient space to allow the installation of two kernel blobs (each roughly the size of the kernel and initrd combined: for future growth in kernel sizes, target 500M or more).

The easiest way to meet most of these requirements is to get grub-efi working with GRUB encrypted boot (`GRUB_ENABLE_CRYPTODISK=y` in `/etc/defaults/grub`) and verify that you can boot using the GRUB UEFI entry by entering the root passphrase when GRUB first starts up. While this measured boot solution by design bypasses GRUB and boots directly from EFI, I recommend retaining a working grub-efi install for recovery and for debugging when the ability to change the kernel command line is required.

**Note for Debian <=12 users:** Debian's build of GRUB 2.06 does not have LUKS2 support built in, which means that if you're on Debian versions through bullseye **you'll need to build your own with that support**; and [it appears to break `GRUB_ENABLE_CRYPTODISK=y`](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=926689), for which the easiest resolution is to **create a boot entry pointing at the monolithic EFI image copied manually to the EFI system partition**. For the latter, I recommend copying it to a different location (e.g., `/boot/efi/EFI/debian/grubx64ml.efi`) and creating an EFI entry pointing at it (e.g., `efibootmgr -c -L 'GRUB (monolithic)' -l '\EFI\debian\grubx64ml.efi'`), so subsequent runs of `grub-install` do not override your changes. Trixie's GRUB 2.12 on the other hand *does* appear to have LUKS2 support out-of-the-box, so the only gotcha is making sure your passphrase is encoded with PBKDF2 instead of Argon2, which as far as I can tell is not supported by any Debian-packaged version of GRUB 2.

Roughly speaking, the steps involved in preparation for install are:

### Don't be lazy

1. Prepare *and test* a hybrid (combined BIOS/EFI) live USB token (or CD/DVD) in case you need to recover from a broken boot setup.

### If your disk is (legacy) MBR-partitioned and/or lacks (or has too small) an EFI system partition (hereafter called "ESP"), convert to GPT and create/resize the required partitions:

1. See the [top answer on this StackExchange question](https://serverfault.com/questions/963178/how-do-i-convert-my-linux-disk-from-mbr-to-gpt-with-uefi). The highlights are:
    * Repartition to add/resize/move the ESP (type `EF00`) so it is at least 500M. (I personally have 1G ESPs. I'm not gonna miss the space, but I will very much feel the annoyance at having to increase its size again during the lifetime of a machine.)
        * You will probably need to do this step from the live image you created earlier, since you won't be able to shrink or move a mounted root partition.
        * This step can be very complicated if you need to move large partitions around to make space. There's no particular reason to place the ESP at the beginning of the disk, so if you don't have enough space there, it's fine to shrink the last data partition to create enough space.
        * Remember to shrink from inner layer to outer and then grow from outer back to inner, leaving enough slack in each reduction to make sure you don't accidentally truncate any of the layers: e.g., for ext4-on-LVM-on-dm-crypt-on-md, `resize2fs`, then `lvresize` (if necessary), then `pvresize`, then `cryptsetup resize`, then `mdadm --grow` (yes, `--grow` is also used to shrink), then `gdisk` or `parted`; then `partprobe`; and then do it all in the reverse order without any sizes specified (layer sizes will be auto-detected) to make sure there's no abandoned space.
        * Please don't come to me for help with this. There are many guides for how to do this all over the web.
    * Format the ESP as VFAT and add a boot entry to `/etc/fstab` mounting it at `/boot/efi`.
    * `mkdir -p /boot/efi && mount /boot/efi`
    * Create one of GRUB's "BIOS boot" partitions (type `EF02`) to support booting grub-pc from a GPT-partitioned disk. This can be tiny (e.g., 1MB), but IIRC it needs to be near the start of large disks because of BIOS geometry limitations (even with LBA translation). Beyond that, you don't need to format or mount this anywhere: GRUB will handle it.
    * Reinstall grub-pc (e.g., `grub-install /dev/sda` for boot disk `/dev/sda`) with the updated partition scheme and reboot to make sure the system is bootable before continuing.

### If you are using the grub-pc (legacy BIOS) bootloader, convert to grub-efi:

1. See the [remaining steps from the top answer on this StackExchange question](https://serverfault.com/questions/963178/how-do-i-convert-my-linux-disk-from-mbr-to-gpt-with-uefi). The highlights are:
    * Install the grub-efi package, which will uninstall grub-pc.
    * Reboot into system setup.
    * Modify system setup to disable CSM and disable Secure Boot.
    * Reboot using the newly-installed grub-efi EFI loader.
1. Optional: delete the GRUB "BIOS boot" partition, which is required only for grub-pc.
1. Add `GRUB_ENABLE_CRYPTODISK=y` to `/etc/default/grub`. (**Note:** This is currently broken in Debian GRUB 2.06, as even with this option the monolithic grub-efi loader is not installed into the ESP.)

### If you have separate boot and root partitions:

1. Copy the contents of the boot partition onto the root filesystem under `/boot`. One way to do this is:
    1. Unmount `/boot/efi` temporarily.
    1. Now unmount `/boot` and remount it somewhere else (e.g., `/mnt`).
    1. Copy the contents of the boot partition to the now-empty `/boot` (e.g., `tar -C /mnt -c . | tar -C /boot -xvp`).
    1. Remount `/boot/efi`.
    1. Remove or comment-out the `/boot` entry in `/etc/fstab`.
1. Re-reinstall grub-efi (e.g., `grub-install /dev/sda` for boot disk `/dev/sda`) with the updated partition scheme, and then reboot to make sure the system is bootable before continuing. If your root device is currently encrypted, you will be prompted for the LUKS passphrase when GRUB starts.
1. Optional: use gdisk to delete the now-vestigial boot partition.

### If your root device is *already* encrypted:

1. Make sure at least one passphrase is stored with PBKDF2, as the Debian version of GRUB 2 as of Trixie (2.12) still does not support the argon2 PBKDF! You'll appreciate having the ability to use GRUB to boot your machine in a pinch, rather than having to boot a live USB disk and manually decrypt and mount partitions. You can re-encode your passphrase with PBKDF2 using `cryptsetup luksConvertKey --pbkdf pbkdf2`.

### If your root device is *not* currently encrypted:

1. Use `cryptsetup reencrypt` to encrypt your disk. This only supports LUKS2 metadata, so you can skip the LUKS1-to-LUKS2 conversion. **Note:** The Debian version of GRUB 2 as of Trixie (2.12) does not support argon2 PBKDF, so make sure to specify `--pbkdf pbkdf2` when adding your initial passphrase.
1. Reinstall grub-efi to make sure the config is updated to load the luks2 module and prompt you for your passphrase. (**Note:** This was broken in Debian GRUB 2.06, which did not have LUKS2 support built-in, but appears to be fixed in Trixie's GRUB 2.12.)
1. Reboot to make sure the system is bootable before continuing.

### If your root device is currently encrypted with LUKS1 metadata:

1. Use `cryptsetup convert --type luks2`. You can do this from the initrd if you use the GRUB shell to add the Linux command line parameter `break` to drop you into busybox during the boot process.
1. Reinstall grub-efi to make sure the config is updated to load the luks2 module and prompt you for your passphrase. (**Note:** This was broken in Debian GRUB 2.06, which did not have LUKS2 support built-in, but appears to be fixed in Trixie's GRUB 2.12.)
1. Reboot to make sure the system is bootable before continuing.

### Enable the TPM

1. Modify your firmware settings (read: "go into BIOS on bootup") to enable the TPM at version 2 with sha256 hashes.

Your system should now be ready to install the EFI measured boot software stack.

## Installation

```
sudo make install
```

Then follow further instructions from the install.

## Future Work

Eventually, I intend to turn this into an official Debian package, though manual steps to prep the system will likely still be required. While it is technically possible to automate the migration to an encrypted root with LUKS2 metadata, there are enough boot chain variations in Debian systems that a user who runs into an uncovered outlying failure case needs sufficient knowledge to be able to recover manually.

## Acknowledgements

This project is heavily dependent on [pcr-oracle](https://github.com/okirch/pcr-oracle) for predicting PCR values in future boot chains. I've modified it slightly to provide additional prediction functionality and to ignore errors that are irrelevant to this solution.

## Licensing

This work is licensed under the MIT License. See the LICENSE file for more information.
