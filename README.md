# Measured Boot for TPM 2.0-enabled UEFI Debian Systems

The primary goal of this project is to prevent unauthorized boot chains (from BIOS up to launching init) from accessing the data on an encrypted root device while allowing authorized boot chains to mount that device at boot time without user interaction (such as passphrase entry). Specific functional requirements include:

- Boot Linux directly from UEFI firmware without an intermediate boot loader (e.g., GRUB).
- Support root filesystems hosted on dm-crypt devices with LUKS2 metadata.
- Store a LUKS passphrase for the root device, sealed to a set of PCRs associated with an approved system state, in a LUKS2 token on the encrypted device.
- Prevent downgrade attacks involving previously-authorized kernel blobs with known vulnerabilities.
- Always fall back to console passphrase entry, even under a broad range of unexpected failure scenarios ("unknown unknowns").
- Automatically update EFI loaders and the sealed LUKS passphrase as kernels are installed/removed and initrd images are updated.

## Preparation

The installation procedure requires that your system be prepared in a few specific ways:

* Your system setup must be configured to boot Linux via an EFI application (e.g., using grub-efi) rather than chaining to a legacy MBR boot loader (like grub-pc).
* You will almost certainly need to disable legacy BIOS boot support (i.e., the CSM or "compatibility support module") as TPM 2.0 interfaces are typically disabled unless your system setup is configured in UEFI-only boot mode.
* The TPM must be enabled in the firmware settings: this can either be discrete (if your motherboard has a separate TPM 2.0 chip) or PTT/fTPM (if you are using the firmware TPM provided by your CPU).
* Secure boot must be disabled, as this software does not currently support signing the resulting EFI loaders.
* The root device must be hosted on a dm-crypt device with LUKS2 metadata (version 2 required for token support).
* `/boot` must not be a separate partition, but instead must be hosted on the encrypted root device.

    This is somewhat of an artificial restriction; an ext2-formatted `/boot` is really irrelevant to this system, as UEFI can only boot UKIs from VFAT partitions. But freeing up the separate boot partition might enable the user to create a larger ESP if the two partitions are contiguous. And anyway removing the plaintext `/boot` reduces the risk of putting potentially sensitive data (such as keys) on an unencrypted partition. It's much easier to reason about the security of the system against offline attacks if all data partitions are encrypted-at-rest.
* You must have a compliant EFI System Partition mounted under `/boot/efi` with sufficient space to allow the installation of two kernel blobs, each roughly the size of the kernel and initrd combined.

    For future growth in kernel sizes, target 1GiB or more. 500MiB is the hard minimum required by this software stack.

The easiest way to meet most of these requirements is to get grub-efi working with GRUB encrypted boot (`GRUB_ENABLE_CRYPTODISK=y` in `/etc/defaults/grub`) and verify that you can boot using the GRUB UEFI entry by entering the root passphrase when GRUB first starts up. While this measured boot solution by design bypasses GRUB and boots directly from EFI, I recommend retaining a working grub-efi install for recovery and for debugging when the ability to change the kernel command line is required. (Note: you will need at least one passphrase to be encoded with PBKDF2, not Argon2, as the latter is not supported by any Debian-packaged version of GRUB 2 as far as I can tell.)

Roughly speaking, the steps involved in preparation for install are:

### Don't be lazy

1. Prepare *and test* a hybrid (combined BIOS/EFI) live USB token (or CD/DVD) in case you need to recover from a broken boot setup.

### If your disk is (legacy) MBR-partitioned and/or lacks (or has too small) an EFI system partition (hereafter called "ESP"), convert to GPT and create/resize the required partitions:

1. See the [top answer on this StackExchange question](https://serverfault.com/questions/963178/how-do-i-convert-my-linux-disk-from-mbr-to-gpt-with-uefi). The highlights are:
    * Repartition to add/resize/move the ESP (type `EF00`) so it is at least 500MiB (1GiB recommended). (I personally have 1G ESPs. I'm not gonna miss the space, but I will very much feel the annoyance at having to increase its size again during the lifetime of a machine.)
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
1. Add `GRUB_ENABLE_CRYPTODISK=y` to `/etc/default/grub`.

### If you have separate boot and root partitions:

1. Copy the contents of the boot partition onto the root filesystem under `/boot`. One way to do this is:
    1. Unmount `/boot/efi` temporarily.
    1. Now unmount `/boot` and remount it somewhere else (e.g., `/mnt`).
    1. Copy the contents of the boot partition to the now-empty `/boot` (e.g., `tar -C /mnt -c . | tar -C /boot -xvp`).
    1. Remount `/boot/efi`.
    1. Remove or comment-out the `/boot` entry in `/etc/fstab`.
1. Re-reinstall grub-efi (e.g., `grub-install /dev/sda` for boot disk `/dev/sda`) with the updated partition scheme, and then reboot to make sure the system is bootable before continuing. If your root device is currently encrypted, you will be prompted for the LUKS passphrase when GRUB starts.
1. Optional: use gdisk to delete the now-vestigial boot partition. Also optional: if the now-vestigial boot partition is contiguous with the ESP, you can combine them into one larger partition!

### If your root device is *already* encrypted:

1. Make sure at least one passphrase is stored with PBKDF2, as the Debian version of GRUB 2 as of Trixie (2.12) still does not support the Argon2 PBKDF! You'll appreciate having the ability to use GRUB to boot your machine in a pinch, rather than having to boot a live USB disk and manually decrypt and mount partitions. You can re-encode your passphrase with PBKDF2 using `cryptsetup luksConvertKey --pbkdf pbkdf2`.

### If your root device is *not* currently encrypted:

1. Use `cryptsetup reencrypt` to encrypt your disk. This only supports LUKS2 metadata, so you can skip the LUKS1-to-LUKS2 conversion. **Note:** The Debian version of GRUB 2 as of Trixie (2.12) does not support Argon2 PBKDF, so make sure to specify `--pbkdf pbkdf2` when adding your initial passphrase.
1. Reinstall grub-efi to make sure the config is updated to load the luks2 module and prompt you for your passphrase.
1. Reboot to make sure the system is bootable before continuing.

### If your root device is currently encrypted with LUKS1 metadata:

1. Use `cryptsetup convert --type luks2`. You can do this from the initrd if you use the GRUB shell to add the Linux command line parameter `break` to drop you into busybox during the boot process.
1. Reinstall grub-efi to make sure the config is updated to load the luks2 module and prompt you for your passphrase.
1. Reboot to make sure the system is bootable before continuing.

### Enable the TPM

1. Modify your firmware settings (read: "go into BIOS on bootup") to enable the TPM at version 2 with sha256 hashes.

Your system should now be ready to install the EFI measured boot software stack.

## Installation

Build and install the package from source:

```
git submodule update --init
dpkg-buildpackage -b -us -uc
sudo apt install ../efi-measured-boot_*.deb
```

Building from source requires `gcc`, `make`, `pkg-config`, `libtss2-dev`, `libjson-c-dev`, and `libssl-dev`.

## Activation

Once the package is installed:

1. **Check system readiness** (optional but recommended):

   ```
   sudo emboot-prepare
   ```

   This guided wizard verifies all prerequisites and can automate a few safe steps
   (such as installing grub-efi and setting `GRUB_ENABLE_CRYPTODISK=y`). Address any
   blocking issues it reports before continuing.

2. **Review configuration** (optional):

   ```
   $EDITOR /etc/efi-measured-boot/config
   ```

   The generated defaults suit most Debian systems. You may want to adjust
   `OS_SHORT_NAME`, `SEAL_PCRS`, or `KERNEL_PARAMS`.

3. **Run first-time setup**:

   ```
   sudo emboot-setup
   ```

   This modifies `/etc/crypttab` to use the emboot unseal keyscript, provisions the
   TPM monotonic anti-downgrade counter, adds a LUKS key for the root device, and sets
   the next EFI boot entry to the emboot loader.

4. **Reboot**:

   ```
   sudo reboot
   ```

   On the first boot via the emboot EFI chain, the system automatically seals the LUKS
   passphrase to the current TPM PCR values. Subsequent kernel installs and removals are
   handled automatically by the package's kernel hooks.

## Booting insecurely in a safe manner to restore measured boot

If for whatever reason (e.g., BIOS upgrade) you know in advance that you're going to need to enter the passphrase on startup, make sure to follow a procedure like the one below to minimize the risk of compromise:

1. First, avoid making any such change when you do not have a secure location available to complete this procedure! Once you've made a change that breaks measured boot, you must wait until getting to a secure location to fix it, or even to boot.

    Ideally, also physically disable networking from here until procedure completion.

1. Second, confirm measured boot success before making the change: this means rebooting once as-normal to confirm machine integrity.

1. Make the breaking change.

1. Now, reboot into emboot. Measured boot will fail and you will be prompted for your passphrase. This is where being in a secure physical location really matters, because—absent a Yubikey or other device that enters your passphrase without someone being able to observe your typing—you may expose your passphrase to a passive adversary.

1. `sudo update-emboot -s`, and confirm via another reboot that measured boot is back in business.

## Acknowledgements

This project is heavily dependent on [pcr-oracle](https://github.com/okirch/pcr-oracle) for predicting PCR values in future boot chains. I've modified it slightly to provide additional prediction functionality and to ignore errors that are irrelevant to this solution.

## Licensing

This work is licensed under the MIT License. See the LICENSE file for more information.
