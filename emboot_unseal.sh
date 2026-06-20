#! /bin/sh

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Kyle R. Rose

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

trap 'rc=$?; trap - EXIT; [ -n "$EMBOOT_NOCLEAN" ] || [ -z "$tmpdir" ] || rm -rf "$tmpdir"; [ -z "$UNSEAL_PAUSE" ] || sleep "$UNSEAL_PAUSE"; [ "$rc" -eq 0 ] && exit 0; fallback' EXIT

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

    EMBOOT_SHARE=/usr/share/efi-measured-boot
    . /etc/efi-measured-boot/config
    . "$EMBOOT_SHARE/functions"

    if would_log -t tpm,boot -l $LL_DEBUG_DETAIL; then set -x; fi

    tmpdir=$(setup_tmp_dir)
    krel=$(uname -r)

    for tid in $(list_luks_token_ids "$CRYPTTAB_SOURCE" "$krel"); do
        export_luks_token "$tmpdir" "$CRYPTTAB_SOURCE" "$tid"

        if unseal_data "$tmpdir" >&3 3>&-; then
            outcome succeeded
            exit 0
        fi
        outcome FAILED

        pcrlist=$(cat "$tmpdir"/pcrlist)
        counterhandle=$(cat "$tmpdir"/counterhandle)

        verbose_do -t tpm,boot -l $LL_INFO eval 'read_pcrs "$pcrlist" >$tmpdir/current_pcrvalues.txt'
        verbose_do -t tpm,boot -l $LL_INFO eval 'read_counter "$counterhandle" "$tmpdir"/current_countervalue'

        log_info -t tpm,boot 'counter %s: current=%d expects<=%d' "$counterhandle" "0x$(xxd -p -c9999 <"$tmpdir"/current_countervalue)" "0x$(xxd -p -c9999 <"$tmpdir"/countervalue)"
        verbose_do -t tpm,boot -l $LL_INFO eval 'diff_pcrs "$pcrlist" "$tmpdir"/pcrvalues "$tmpdir"/current_pcrvalues.txt | sed -e "s/^/  /"'
    done

    [ -n "$EMBOOT_NOCLEAN" ] || rm -rf "$tmpdir"
    log 'Falling back to passphrase entry'
fi

exec "$keyscript" "$keyscriptarg" >&3 3>&-
