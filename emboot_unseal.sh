#! /bin/sh

exec 3>&1 1>&2

cmd=$0

keyscript="/lib/cryptsetup/askpass"
keyscriptarg="Please unlock disk${CRYPTTAB_NAME:+ $CRYPTTAB_NAME}: "

tmpdir=

fallback() {
    echo "$(basename "$cmd") failed with exit code $rc"
    test -n "$tmpdir" && rm -rf "$tmpdir"
    exec "$keyscript" "$keyscriptarg" 1>&3 3>&-
}

trap 'rc=$?; [ "$rc" -eq 0 ] && exit 0; fallback' EXIT

set -e

if [ "$CRYPTTAB_TRIED" = 0 ]; then
    . /etc/efi-measured-boot/config
    if [ -z "${cmd##./*}" ]; then APPDIR=.; fi
    . "${APPDIR:-.}"/functions

    tmpdir=$(setup_tmp_dir)

    for tid in $(list_luks_token_ids "$CRYPTTAB_SOURCE" "$(uname -r)"); do
        export_luks_seal_metadata "$tmpdir" "$CRYPTTAB_SOURCE" "$tid"

        create_provision_context "$tmpdir"
        if unseal_data "$tmpdir" 1>&3 3>&-; then
            echo "$(basename "$cmd")${CRYPTTAB_SOURCE:+ of $CRYPTTAB_SOURCE} succeeded${CRYPTTAB_NAME:+ for $CRYPTTAB_NAME} using token ID $tid"
            exit 0
        fi
        echo "$(basename "$cmd")${CRYPTTAB_SOURCE:+ of $CRYPTTAB_SOURCE} failed${CRYPTTAB_NAME:+ for $CRYPTTAB_NAME} using token ID $tid"
    done

    rm -rf "$tmpdir"
    echo "Falling back to passphrase entry"
fi

exec "$keyscript" "$keyscriptarg" 1>&3 3>&-
