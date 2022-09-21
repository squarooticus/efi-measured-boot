#! /bin/sh

exec 3>&1 >&2

cmd=$0

keyscript="/lib/cryptsetup/askpass"
keyscriptarg="Please unlock disk${CRYPTTAB_NAME:+ $CRYPTTAB_NAME}: "

tmpdir=

fallback() {
    echo "$(basename "$cmd") failed with exit code $rc"
    echo "Falling back to passphrase entry"
    test -n "$tmpdir" && rm -rf "$tmpdir"
    exec "$keyscript" "$keyscriptarg" >&3 3>&-
}

trap 'rc=$?; [ -z "$UNSEAL_PAUSE" ] || sleep "$UNSEAL_PAUSE"; [ "$rc" -eq 0 ] && exit 0; fallback' EXIT

set -e

outcome() {
    echo "EFI measured boot unseal $1"
    if [ "$1" != succeeded -o "${VERBOSE:-0}" != 0 ]; then
        [ -z "${CRYPTTAB_SOURCE}" ] || echo "  backing device: ${CRYPTTAB_SOURCE}"
        [ -z "${CRYPTTAB_NAME}" ] || echo "  mapped name: ${CRYPTTAB_NAME}"
        echo "  token ID: $tid"
        echo "  kernel release: $krel"
    fi
}

if [ "$CRYPTTAB_TRIED" = 0 ]; then
    . /etc/efi-measured-boot/config
    if [ -z "${cmd##./*}" ]; then APPDIR=.; fi
    . "${APPDIR:-.}"/functions

    tmpdir=$(setup_tmp_dir)

    if [ "${VERBOSE:-0}" != 0 ]; then
        read_pcrs >$tmpdir/current_pcrs.txt
    fi

    krel=$(uname -r)
    for tid in $(list_luks_token_ids "$CRYPTTAB_SOURCE" "$krel"); do
        export_luks_token "$tmpdir" "$CRYPTTAB_SOURCE" "$tid"

        if [ "${VERBOSE:-0}" != 0 ]; then
            diff_pcrs $tmpdir/pcrs $tmpdir/current_pcrs.txt
        fi

        if unseal_data "$tmpdir" >&3 3>&-; then
            outcome succeeded
            exit 0
        fi
        outcome FAILED
    done

    rm -rf "$tmpdir"
    echo "Falling back to passphrase entry"
fi

exec "$keyscript" "$keyscriptarg" >&3 3>&-
