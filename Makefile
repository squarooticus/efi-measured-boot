all:
	@echo "make deb      Build the Debian package" >&2
	@echo "make checks   Run runtime safety checks (requires installed package)" >&2

deb:
	dpkg-buildpackage -b -us -uc

checks:
	@./safety_checks
	@echo "Safety checks passed" >&2
