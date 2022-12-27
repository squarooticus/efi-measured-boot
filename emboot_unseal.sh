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

if [ "$CRYPTTAB_TRIED" = 0 ]; then
    outcome() {
        echo "EFI measured boot unseal $1"
        if [ "$1" != succeeded ] || is_verbose; then
            [ -z "${CRYPTTAB_SOURCE}" ] || echo "  backing device: ${CRYPTTAB_SOURCE}"
            [ -z "${CRYPTTAB_NAME}" ] || echo "  mapped name: ${CRYPTTAB_NAME}"
            echo "  token ID: $tid"
            echo "  kernel release: $krel"
        fi
    }

    kill_children() {
        jobs -p >$tmpdir/children
        children=$(cat $tmpdir/children)
        if [ -n "$children" ]; then
            verbose_do -l 1 echo "Killing child PIDs $children"
            kill "$@" $children >/dev/null 2>&1
        fi
        return 0
    }

    . /etc/efi-measured-boot/config
    [ -n "${cmd##./*}" ] || APPDIR=.
    . "${APPDIR:-/APPDIR-not-set}"/functions

    if is_verbose 5; then set -x; fi

    tmpdir=$(setup_tmp_dir)

    verbose_do eval 'read_pcrs >$tmpdir/current_pcrs.txt'
    verbose_do eval 'read_counter "$tmpdir"/current_counter'

    krel=$(uname -r)
    for tid in $(list_luks_token_ids "$CRYPTTAB_SOURCE" "$krel"); do
        export_luks_token "$tmpdir" "$CRYPTTAB_SOURCE" "$tid"

        if unseal_data "$tmpdir" >&3 3>&-; then
            outcome succeeded
            exit 0
        fi
        outcome FAILED

        verbose_do eval 'printf "  counter: current=%d expects<=%d\n" "0x$(xxd -p -c9999 <$tmpdir/current_counter)" "0x$(xxd -p -c9999 <$tmpdir/counter)"'
        verbose_do eval 'diff_pcrs "$tmpdir"/pcrs "$tmpdir"/current_pcrs.txt | sed -e "s/^/  /"'
    done

    echo "Falling back to passphrase entry"

    if [ -n "$UNSEAL_FAILED_CMD" ]; then
        verbose_do -l 1 echo "Running unseal failed command: $UNSEAL_FAILED_CMD"
        eval "$UNSEAL_FAILED_CMD"
        jobs

        "$keyscript" "$keyscriptarg" >&3 3>&-
        rc=$?

        kill_children; sleep 1; kill_children -9
        rm -rf "$tmpdir"

        trap - EXIT
        exit $rc
    fi

    rm -rf "$tmpdir"
fi

exec "$keyscript" "$keyscriptarg" >&3 3>&-
