#! /bin/sh

exec 3>&1 1>&2

cmd=$0

keyscript="/lib/cryptsetup/askpass"
keyscriptarg="Please unlock disk $CRYPTTAB_NAME: "

trap 'rc=$?; [ "$rc" -eq 0 ] && exit 0; umount_efi; echo "$(basename $cmd) failed with exit code $rc"; -n "$oldpwd" && cd "$oldpwd"; exec "$keyscript" "$keyscriptarg" 1>&3 3>&-' EXIT

set -e

if [ "$CRYPTTAB_TRIED" = 0 ]; then
    emboot_tmp=/tmp/emboot
    mkdir -p "$emboot_tmp"
    oldpwd=$(pwd)
    cd "$emboot_tmp"

    . /etc/efi-measured-boot/config
    . "$APPDIR"/functions

    mount_efi
    for i in counter sealed.pub sealed.priv; do
        cp -f "$EFI_MOUNT/EFI/$OS_SHORT_NAME/emboot/$(uname -r)/$i" "$emboot_tmp/"
    done
    umount_efi

    create_provision_context
    if unseal_data 1>&3 3>&-; then
        echo "$(basename $cmd) succeeded"
        exit 0
    fi

    echo "$(basename $cmd) failed"
    cd "$oldpwd"
fi

exec "$keyscript" "$keyscriptarg" 1>&3 3>&-
