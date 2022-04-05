SYSTEMD_STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub

all:
	@echo "make checks      Perform safety checks" >&2
	@echo "make install     Start install" >&2

checks:
	@./safety_checks
	@echo "Safety checks passed" >&2

install: checks
	@./prep_emboot
	@echo "First step complete: checks /etc/efi-measured-boot/config and run make step2 when ready" >&2

step2: checks
	@./prep_emboot_2
	@echo "Step two complete: reboot (using your LUKS passphrase when prompted) and run make step3 if successful" >&2

step3: checks
	@./emboot_seal_key
	@./emboot_update_efi_boot_order
	@echo "Installation complete: run update-emboot whenever kernel or initrd are updated" >&2
