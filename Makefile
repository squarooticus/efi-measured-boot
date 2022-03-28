SYSTEMD_STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub

all:
	@echo "make checks      Perform safety checks" 1>&2
	@echo "make install     Start install" 1>&2

checks:
	@./safety_checks
	@echo "Safety checks passed" 1>&2

install: checks
	@./prep_emboot
	@echo "First step complete: checks /etc/efi-measured-boot/config and run make step2 when ready" 1>&2

step2: checks
	@./prep_emboot_2
	@echo "Step two complete: reboot (using your LUKS passphrase when prompted) and run make step3 if successful" 1>&2

step3: checks
	@./emboot_seal_key
	@echo "Installation complete: run update-emboot whenever kernel or initrd are updated" 1>&2
	@echo "You will likely also want to change your boot order now to boot the new measured boot entry by default" 1>&2
