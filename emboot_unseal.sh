#! /bin/sh

exec 3>&1 >&2

cmd=$0

keyscript="/lib/cryptsetup/askpass"
keyscriptarg="Please unlock disk${CRYPTTAB_NAME:+ $CRYPTTAB_NAME}: "

tmpdir=

fallback() {
    echo "$(basename "$cmd") failed with exit code $rc"
    echo "Falling back to passphrase entry"
    exec "$keyscript" "$keyscriptarg" >&3 3>&-
}

trap 'rc=$?; trap - EXIT; [ -z "$tmpdir" ] || rm -rf "$tmpdir"; [ -z "$UNSEAL_PAUSE" ] || sleep "$UNSEAL_PAUSE"; [ "$rc" -eq 0 ] && exit 0; fallback' EXIT

set -e

if [ "$CRYPTTAB_TRIED" = 0 ]; then
    outcome() {
        log 'EFI measured boot unseal %s' "$1"
        local log_prio=$LL_INFO
        [ "$1" = succeeded ] || log_prio=$LL_ERROR
        [ -z "${CRYPTTAB_SOURCE}" ] || log -t boot -l $log_prio 'backing device: %s' "${CRYPTTAB_SOURCE}"
        [ -z "${CRYPTTAB_NAME}" ] || log -t boot -l $log_prio 'mapped name: %s' "${CRYPTTAB_NAME}"
        log -t boot -l $log_prio 'token ID: %s' "$tid"
        log -t boot -l $log_prio 'kernel release: %s' "$krel"
    }

    . /etc/efi-measured-boot/config
    [ -n "${cmd##./*}" ] || APPDIR=.
    . "${APPDIR:-/APPDIR-not-set}"/functions

    if would_log -t tpm,boot -l $LL_DEBUG_DETAIL; then set -x; fi

    tmpdir=$(setup_tmp_dir)

    verbose_do -t tpm,boot -l $LL_INFO eval 'read_pcrs >$tmpdir/current_pcrs.txt'
    verbose_do -t tpm,boot -l $LL_INFO eval 'read_counter "$tmpdir"/current_counter'

    krel=$(uname -r)
    for tid in $(list_luks_token_ids "$CRYPTTAB_SOURCE" "$krel"); do
        export_luks_token "$tmpdir" "$CRYPTTAB_SOURCE" "$tid"

        if unseal_data "$tmpdir" >&3 3>&-; then
            outcome succeeded
            exit 0
        fi
        outcome FAILED

        log_info -t tpm,boot 'counter: current=%d expects<=%d' "0x$(xxd -p -c9999 <$tmpdir/current_counter)" "0x$(xxd -p -c9999 <$tmpdir/counter)"
        verbose_do -t tpm,boot -l $LL_INFO eval 'diff_pcrs "$tmpdir"/pcrs "$tmpdir"/current_pcrs.txt | sed -e "s/^/  /"'
    done

    rm -rf "$tmpdir"
    log 'Falling back to passphrase entry'
fi

exec "$keyscript" "$keyscriptarg" >&3 3>&-
