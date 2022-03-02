octothorpe=\#
SYSTEMD_STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
SHELL=/bin/bash

CHECKS=root arch no_separate_boot mounted_efi root_luks systemd_stub tpm packages

install: check
	@./scripts/prep_emboot
	@echo "First step complete: check /etc/efi-measured-boot/config and run make step2 when ready" 1>&2

step2: check
	@./scripts/prep_emboot_2
	@echo "Step two complete: reboot (using your LUKS passphrase when prompted) and run make step3 if successful" 1>&2

step3: check
	@./scripts/emboot_seal_key
	@echo "Installation complete: run update-emboot whenever kernel or initrd are updated" 1>&2
	@echo "You will likely also want to change your boot order now to boot the new measured boot entry by default" 1>&2

check: $(addprefix check_,$(CHECKS))
	@echo "CHECKS SUCCESSFUL" 1>&2

check_root:
	@if test "$$(id -u)" != 0; then \
		echo "Must run as root (e.g., using sudo)" 1>&2; \
		exit 1; \
	fi

check_arch:
	@if test "$$(uname -m)" != "x86_64"; then \
		echo "Unsupported architecture $$(uname -m)" 1>&2; \
		exit 1; \
	fi

check_no_separate_boot:
	@if test "$$(stat -c '%m' /boot)" != "/"; then \
		echo "/boot not on root device unsupported" 1>&2; \
		exit 1; \
	fi

check_mounted_efi:
	@if test "$$(stat -c '%m' /boot/efi)" != "/boot/efi"; then \
		echo "EFI system partition must be mounted at /boot/efi" 1>&2; \
		exit 1; \
	elif test "$$(stat -f -c '%T' /boot/efi)" != "msdos" -o \
			"$$(mount | awk '$$3 == "/boot/efi" { print $$5; }')" != "vfat"; then \
		echo "Filesystem mounted at /boot/efi must be mounted as type vfat" 1>&2; \
		exit 1; \
	fi

check_root_luks:
	@cryptdev=( $$(./scripts/get_crypttab_entry $$(./scripts/get_device_info / | awk '{print $$2;}') ) ); \
		if (( $${$(octothorpe)cryptdev[@]} == 0 )); then \
			echo "Root has no parent crypttab entry" 1>&2; \
			exit 1; \
		elif [[ $${cryptdev[3]} != *luks* ]]; then \
			echo "crypttab entry missing luks option: $${cryptdev[3]}" 1>&2; \
			exit 1; \
		fi

check_systemd_stub:
	@if ! test -r $(SYSTEMD_STUB); then \
		echo "systemd EFI stub $(SYSTEMD_STUB) not available" 1>&2; \
	fi

check_tpm:
	@if ! tpm2_pcrread -Q 2>/dev/null; then \
		echo "TPM does not appear to be available or working" 1>&2; \
		exit 1; \
	fi

check_packages:
	@if (( $$(dpkg-query -W -f='$${Status}\n' initramfs-tools gdisk 2>/dev/null | grep -c "ok installed") < 2 )); then \
		echo "initramfs-tools required (dracut is not supported)" 1>&2; \
		exit 1; \
	fi
