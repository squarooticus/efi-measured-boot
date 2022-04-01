#! /bin/sh

exec 3>&1 1>&2

cmd=$0

keyscript="/lib/cryptsetup/askpass"
keyscriptarg="Please unlock disk${CRYPTTAB_NAME:+ $CRYPTTAB_NAME}: "

tmpdir=

trap 'rc=$?; [ "$rc" -eq 0 ] && exit 0; umount_efi; echo "$(basename $cmd) failed with exit code $rc"; test -n "$oldpwd" && cd "$oldpwd"; test -n "$tmpdir" && rm -rf "$tmpdir"; exec "$keyscript" "$keyscriptarg" 1>&3 3>&-' EXIT

set -e

if [ "$CRYPTTAB_TRIED" = 0 ]; then
    . /etc/efi-measured-boot/config
    if [ -z "${cmd##./*}" ]; then APPDIR=.; fi
    . "${APPDIR:-.}"/functions

    tmpdir=$(setup_tmp_dir)

    mount_efi
    cp -f "$(emboot_state_path "$(uname -r)")"/* "$tmpdir/"
    umount_efi

    oldpwd=$(pwd)
    cd "$tmpdir"

    create_provision_context
    if unseal_data 1>&3 3>&-; then
        echo "$(basename $cmd) succeeded${CRYPTTAB_NAME:+ for $CRYPTTAB_NAME}"
        exit 0
    fi

    cd "$oldpwd"
    rm -rf "$tmpdir"
    echo "$(basename $cmd) failed${CRYPTTAB_NAME:+ for $CRYPTTAB_NAME}"
fi

exec "$keyscript" "$keyscriptarg" 1>&3 3>&-
