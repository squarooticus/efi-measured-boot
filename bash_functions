#! /bin/bash

. "${APPDIR:-/APPDIR-not-set}"/functions

# Shell quotes with an attempt to make the result human-readable.
quote_args() {
    local sq="'"
    local dq='"'
    local fs=/
    local space=""
    local qw
    local w
    for w; do
        if [ -n "$w" -a -z "${w//[0-9a-zA-Z_,.:=$fs-]}" ]; then
            printf %s "$space$w"
        else
            qw="$sq${w//$sq/$sq$dq$sq$dq$sq}$sq"
            qw=${qw//$sq$sq}
            printf %s "$space${qw:-$sq$sq}"
        fi
        space=" "
    done
}

# Compares two dot-delimited decimal-element version numbers a and b that may
# also have arbitrary string suffixes. Compatible with semantic versioning, but
# not as strict: comparisons of non-semver strings may have unexpected
# behavior.
#
# Returns:
# 1 if a<b
# 2 if equal
# 3 if a>b
compare_versions() {
    local LC_ALL=C

    # Optimization
    if [[ $1 == "$2" ]]; then
        return 2
    fi

    # Compare numeric release versions. Supports an arbitrary number of numeric
    # elements (i.e., not just X.Y.Z) in which unspecified indices are regarded
    # as 0.
    local aver=${1%%[^0-9.]*} bver=${2%%[^0-9.]*}
    local arem=${1#$aver} brem=${2#$bver}
    local IFS=.
    local i a=($aver) b=($bver)
    for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
        if ((10#${a[i]:-0} < 10#${b[i]:-0})); then
            return 1
        elif ((10#${a[i]:-0} > 10#${b[i]:-0})); then
            return 3
        fi
    done

    # Remove build metadata before remaining comparison
    arem=${arem%%+*}
    brem=${brem%%+*}

    # Prelease (w/remainder) always older than release (no remainder)
    if [ -n "$arem" -a -z "$brem" ]; then
        return 1
    elif [ -z "$arem" -a -n "$brem" ]; then
        return 3
    fi

    # Otherwise, split by periods and compare individual elements either
    # numerically or lexicographically
    local a=(${arem#-}) b=(${brem#-})
    for ((i=0; i<${#a[@]} && i<${#b[@]}; i++)); do
        local anns=${a[i]#${a[i]%%[^0-9]*}} bnns=${b[i]#${b[i]%%[^0-9]*}}
        if [ -z "$anns$bnns" ]; then
            # Both numeric
            if ((10#${a[i]:-0} < 10#${b[i]:-0})); then
                return 1
            elif ((10#${a[i]:-0} > 10#${b[i]:-0})); then
                return 3
            fi
        elif [ -z "$anns" ]; then
            # Numeric comes before non-numeric
            return 1
        elif [ -z "$bnns" ]; then
            # Numeric comes before non-numeric
            return 3
        else
            # Compare lexicographically
            if [[ ${a[i]} < ${b[i]} ]]; then
                return 1
            elif [[ ${a[i]} > ${b[i]} ]]; then
                return 3
            fi
        fi
    done

    # Fewer elements is earlier
    if ((${#a[@]} < ${#b[@]})); then
        return 1
    elif ((${#a[@]} > ${#b[@]})); then
        return 3
    fi

    # Must be equal!
    return 2
}

# Sorts the given array according to the given comparison function. The
# comparison function must satisfy the return value scheme from
# compare_versions above, with return value 4 indicating comparison error.
qsort() {
    local aname=$1
    declare -n aref=$aname
    local compare=$2
    local start=${3:-0}
    local end=${4:-$((${#aref[@]} - 1))}

    # Algorithm based on Hoare partitioning pseudocode at
    # https://en.wikipedia.org/wiki/Quicksort
    if ((start >= end)); then
        return
    fi
    local pivot=${aref[$start]}
    local i=$((start - 1))
    local j=$((end + 1))
    local cmpi cmpj
    while true; do
        ((i++))
        $compare "${aref[$i]}" "$pivot"
        cmpi=$?
        while ((cmpi < 2)); do
            ((i++))
            $compare "${aref[$i]}" "$pivot"
            cmpi=$?
        done
        if ((cmpi == 4)); then return 4; fi

        ((j--))
        $compare "${aref[$j]}" "$pivot"
        cmpj=$?
        while ((cmpj > 2 && cmpj != 4)); do
            ((j--))
            $compare "${aref[$j]}" "$pivot"
            cmpj=$?
        done
        if ((cmpi == 4)); then return 4; fi

        if ((i >= j)); then
            break
        fi

        local swap=${aref[$i]}
        aref[$i]=${aref[$j]}
        aref[$j]=$swap
    done
    qsort "$aname" "$compare" $start $j
    qsort "$aname" "$compare" $((j + 1)) $end
}

# Provisions the monotonic counter used to prevent downgrade attacks, unless
# one with the correct properties already exists. Errors if the NV handle is in
# use with conflicting properties.
provision_counter() {
    if lc_tpm tpm2_nvreadpublic "$COUNTER_HANDLE"; then
        eval "$(lc_tpm tpm2_nvreadpublic "$COUNTER_HANDLE" | parse_yaml '' nvmd_)"
        local invar=nvmd_$(printf "0x%x" $COUNTER_HANDLE)_attributes_value
        if [ -z "${!invar}" ]; then
            echo "Cannot parse attributes for NV index $COUNTER_HANDLE" >&2
            return 1
        fi
        declare -i attrs=${!invar}
        if (( (attrs & 0x20200f2) != 0x2020012 )); then
            echo "Conflicting counter with invalid attributes at NV index $COUNTER_HANDLE (value=$attrs)" >&2
            return 1
        fi
        echo "Using existing counter at NV index $COUNTER_HANDLE" >&2
    else
        if ! lc_tpm tpm2_nvdefine "$COUNTER_HANDLE" -C o -s 8 -a 'ownerread|ownerwrite|no_da|nt=counter'; then
            echo "Unable to create counter at NV index $COUNTER_HANDLE" >&2
            return 1
        fi
    fi
    lc_tpm tpm2_nvincrement -C o "$COUNTER_HANDLE" && \
        lc_tpm tpm2_shutdown
}

# Given a device node, returns the disk node and partition number. Sanity
# checks that the partition UUID of the input and output match.
device_to_disk_and_partition() {
    local dev=$1
    local devpartuuid=$(lsblk -n -o PARTUUID -r "$dev" | tr a-z A-Z)
    local parents=( $(lsblk -s -n -o NAME -r "$dev" | tail -n +2) )
    if ((${#parents[@]} != 1)); then
        echo "Do not know how to handle $dev with other than one parent: ${parents[*]}" >&2
        return 1
    fi
    local disk=/dev/${parents[0]}
    local part=$(printf %s "$dev" | grep -o '[0-9]\+$')
    local checkuuid=$(sgdisk "$disk" -i "$part" | grep -i 'Partition unique GUID' | sed 's/^.*://; s/[[:space:]]\+//g' | tr a-z A-Z)
    if [[ $devpartuuid != "$checkuuid" ]]; then
        echo "PARTUUID mismatch: $dev ($devpartuuid) somehow not $disk partition $part ($checkuuid)" >&2
        return 1
    fi
    printf %s "$disk $part"
}

# Given a device node, output the unique entry from /etc/crypttab covering that
# device (e.g., containing that partition or LVM logical volume or whatever).
get_crypttab_entry() {(
    local devnode=$1

    set -e

    local parentdevices=( $(lsblk -s -t $devnode -o UUID -n -r | grep '.' | sort | uniq) )
    local OLDIFS=$IFS
    local IFS=$'\n'
    local crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep 'UUID=\('"$(any_of_bre "${parentdevices[@]}")"'\)' || true) )
    if ((${#parentdevices[@]} == 0 || ${#crypttabentries[@]} == 0)); then
        echo 'crypttab entry not found via UUID; trying node' >&2
        IFS=$OLDIFS
        local parentdevices=( $(lsblk -p -s -t $devnode -o NAME -n -r | grep '.' | sort | uniq) )
        IFS=$'\n'
        crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep "$(any_of_bre "${parentdevices[@]}")" || true) )
    fi
    IFS=$OLDIFS
    if ((${#parentdevices[@]} == 0 || ${#crypttabentries[@]} == 0)); then
        echo 'crypttab entry not found' >&2
        exit 1
    fi
    if ((${#crypttabentries[@]} > 1)); then
        echo 'Filesystem in multiple crypttab entries unsupported' >&2
        IFS=$'\n'; printf %s\\n "${crypttabentries[*]}"
        exit 1
    fi
    local cryptdev=( ${crypttabentries[0]} )

    IFS=' '
    printf %s "${cryptdev[*]}"
)}

# Given a path, output `UUID device_node_path` for the containing filesystem.
get_device_info() {(
    local trace_path=${1:-/}

    set -e

    local mount_point=$(stat -c '%m' $trace_path)
    local dev=( $(lsblk -n -o UUID,PATH,MOUNTPOINT -r | awk '$3 == "'"$mount_point"'" { print $1 " " $2; }') )
    if ((${#dev[@]} == 0)); then
        echo "No block device found with mount point $mount_point" >&2
        exit 1
    fi

    printf %s "${dev[0]} ${dev[1]}"
)}

# Output a space-separated list of kernel images in /boot in reverse order
# (highest first).
list_installed_kernels() {(
    declare -a kvers
    shopt -s nullglob
    local kvers=( /boot/vmlinuz* )

    set +e

    kver_descending() {
        local vers=( $(kernel_path_to_release "$@") )
        # Strip the trailing -<arch> because by semver rules it would cause the
        # numeric Debian revision to be compared as a string.
        vers=( "${vers[@]%%-[^/0-9.-]*}" )
        if ((${#vers[@]} != 2)); then return 4; fi
        compare_versions "${vers[@]}"
        local rc=$?
        return $((4-rc))
    }

    qsort kvers kver_descending
    if (($? == 4)); then return 1; fi

    local IFS=" "
    printf %s "${kvers[*]}"
)}

# Populates:
#
#   - An associative array `efi_apps` mapping uppercase loader path to a
#   tab-separated string with fields (bootnum, display name, partition UUID,
#   loader)
#
#   - An array `efi_boot_order` containing the boot order (each element of
#   which is 4 hex digits)
#
#   - A string `efi_boot_current` containing the current boot entry (also 4 hex
#   digits)
#
# Caches the result. Use `evict_efi_vars` to evict this cache if the EFI vars
# are known to have changed.
read_efi_vars() {
    if [ -z "$efi_vars_available" ]; then
        declare -gA efi_apps=()
        local oldIFS=$IFS
        local IFS=$'\t'
        local loader bootnum desc partuuid
        while read -r loader bootnum desc partuuid; do
            verbose_do -l $LL_EFI eval 'printf "  reading EFI entry %s: desc=%s partuuid=%s loader=%s\n" "$bootnum" "$desc" "$partuuid" "$loader" >&2'
            efi_apps[$(printf %s "$loader" | tr a-z A-Z)]="$bootnum"$'\t'"$desc"$'\t'"$partuuid"$'\t'"$loader"
        done < <(lc_efi efibootmgr -v | grep '^Boot[0-9a-fA-F]\{4\}' | sed -e 's/^Boot\([0-9a-fA-F]\{4\}\)[\* ] \([^\t]\+\)\tHD([0-9]\+,GPT,\([0-9a-fA-F-]\+\),.*File(\([^)]\+\)).*/\4\t\1\t\2\t\3/')

        local IFS=','
        declare -ga efi_boot_order
        efi_boot_order=( $(efibootmgr -v | grep '^BootOrder' | sed -e 's/^BootOrder: *//') )
        local IFS=$oldIFS
        verbose_do -l $LL_EFI eval 'printf "  EFI boot order: ${efi_boot_order[*]}\n" >&2'

        declare -g efi_boot_current
        efi_boot_current=$(efibootmgr -v | grep '^BootCurrent' | sed -e 's/^BootCurrent: *//')
        verbose_do -l $LL_EFI eval 'printf "  EFI boot current: %s\n" "$efi_boot_current" >&2'

        declare -g efi_vars_available=1
    fi
    return 0
}

evict_efi_vars() {
    declare -g efi_vars_available=
}

# Given a loader filename (no path: it must be in
# $EFI_MOUNT/EFI/$OS_SHORT_NAME) and an optional tag (otherwise the empty
# string), creates a new EFI boot entry for that loader with the OS short name
# and the optional tag.
create_emboot_efi_entry() {
    local loader_basename=$1
    local tag=$2
    local efidevinfo=( $(get_device_info "$EFI_MOUNT") )
    local efi_disk_and_part=( $(device_to_disk_and_partition "${efidevinfo[1]}") )
    local efidisk=${efi_disk_and_part[0]}
    local efipartition=${efi_disk_and_part[1]}
    local loader="\\EFI\\$OS_SHORT_NAME\\$loader_basename"
    lc_efi efibootmgr -C -d "$efidisk" -p "$efipartition" -l "$loader" -L "$OS_SHORT_NAME emboot${tag:+ ($tag)}"
}

# Given a crypto device, populates `luksmd` with the output of dumping the LUKS
# metadata for the crypto device in JSON format.
read_luks_metadata() {
    local cryptdev=$1
    declare -gA luksmd
    [ -n "${luksmd[$cryptdev]}" ] || luksmd[$cryptdev]=$(lc_crypt cryptsetup luksDump "$cryptdev" --dump-json-metadata)
    return 0
}

# Evicts the cache for the given device or for all devices
evict_luks_metadata() {
    local cryptdev=$1
    declare -gA luksmd
    if [ -n "$cryptdev" ]; then
        luksmd[$cryptdev]=
    else
        luksmd=()
    fi
}

# Outputs a space-separated list of token IDs associated with emboot, and
# kernel release (if specified). Bash version making use of associative array.
list_luks_token_ids() {
    local cryptdev=$1
    local krel=$2
    read_luks_metadata "$cryptdev"
    printf "%s" "${luksmd[$cryptdev]:-$(lc_crypt cryptsetup luksDump "$cryptdev" --dump-json-metadata)}" | lc_misc jq -j '."tokens" | to_entries | map(select(."value"."type" == "emboot"'"${krel:+ and .\"value\".\"krel\" == \"$krel\"}"')) | map(.key) | sort | join(" ")'
}

# Outputs the index of the emboot key slot. If there is an existing emboot
# token, pulls this directly from it; if not, tests the key against all
# keyslots until it finds a match.
get_emboot_key_slot() {
    local cryptdev=$1
    read_luks_metadata "$cryptdev"
    local emboot_token_ids=( $(list_luks_token_ids "$cryptdev") )
    local first_keyslot
    if ((${#emboot_token_ids[@]} > 0)); then
        local one_token_id=${emboot_token_ids[0]}
        first_keyslot=$(printf "%s" "${luksmd[$cryptdev]}" | lc_misc jq -j '.tokens."'"$one_token_id"'".keyslots | first')
        if [ -n "$first_keyslot" -a "$first_keyslot" != "null" ]; then
            if lc_crypt cryptsetup luksOpen --test-passphrase -d "$LUKS_KEY" --key-slot "$first_keyslot" "$cryptdev" </dev/null >/dev/null 2>&1; then
                verbose_do -l 1 echo "Passphrase found in keyslot $first_keyslot (from token $one_token_id)" >&2
                printf %s "$first_keyslot"
                return 0
            else
                verbose_do -l 1 echo "Passphrase NOT found in keyslot $first_keyslot from token $one_token_id" >&2
            fi
        fi
    fi
    local keyslots=( $(printf "%s" "${luksmd[$cryptdev]}" | lc_misc jq -j '.keyslots | keys | join(" ")') )
    local i
    for i in "${keyslots[@]}"; do
        if [ "$i" = "$first_keyslot" ]; then
            verbose_do -l 1 echo "Skipping keyslot $i" >&2
        elif lc_crypt cryptsetup luksOpen --test-passphrase -d "$LUKS_KEY" --key-slot "$i" "$cryptdev" </dev/null >/dev/null 2>&1; then
            verbose_do -l 1 echo "Passphrase found in keyslot $i" >&2
            printf %s "$i"
            return 0
        fi
    done
    return 1
}

# Composes JSON for sealed key data in the working directory and imports it as
# a new LUKS token.
import_luks_token() {
    local workdir=${1:-.}
    local cryptdev=$2
    local krel=$3
    declare -a args
    local json=
    local k
    for k in counter pcrs sealed.priv sealed.pub; do
        b64encode -w 0 <$workdir/$k >$workdir/$k.b64
        args+=( --rawfile "${k//./_}" "$workdir/$k.b64" )
        json+=", \"$k\": \$${k//./_}"
    done
    local keyslot=$(get_emboot_key_slot "$cryptdev")
    [ -n "$keyslot" ] || {
        echo "No key slots on $cryptdev matching $LUKS_KEY" >&2
        return 1
    }
    lc_misc jq --null-input "${args[@]}" --arg krel "$krel" --arg keyslot "$keyslot" --arg updated "$(date +%s)" '{ "type": "emboot", "keyslots": [ $keyslot ], "krel": $krel, "updated": $updated'"$json"' }' >$workdir/token.json
    local current_token_ids=( $(list_luks_token_ids "$cryptdev" "$krel") )
    for k in "${current_token_ids[@]}"; do
        lc_crypt cryptsetup token remove "$cryptdev" --token-id "$k"
    done
    lc_crypt cryptsetup token import "$cryptdev" --json-file "$workdir"/token.json

    evict_luks_metadata "$cryptdev"
}

# Removes LUKS tokens for a given kernel release.
remove_luks_token() {
    local cryptdev=$1
    local krel=$2
    local krel_token_ids=( $(list_luks_token_ids "$cryptdev" "$krel") )
    for k in "${krel_token_ids[@]}"; do
        lc_crypt cryptsetup token remove "$cryptdev" --token-id "$k"
    done
    evict_luks_metadata "$cryptdev"
}

stub_does_extra_pcr_4_measurement() {
    bsa_count=$(lc_tpm tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements 2>/dev/null | awk '
    $1 == "-" && $2 == "EventNum:" { inpcr4=0; inbsa=0; next}
    $1 == "PCRIndex:" && $2 == "4" { inpcr4=1; next }
    inpcr4 && $1 == "EventType:" && $2 == "EV_EFI_BOOT_SERVICES_APPLICATION" { inbsa=1; print "pcr4bsa"; next }' | wc -l)
    if (( bsa_count == 1 )); then
        verbose_do -l $LL_TPM_DEBUG echo "One BSA event: assuming old stub" >&2
        return 1
    elif (( bsa_count == 2 )); then
        verbose_do -l $LL_TPM_DEBUG echo "Two BSA events: assuming new stub; will measure kernel section" >&2
        return 0
    else
        verbose_do -l $LL_TPM_DEBUG echo "BSA event count is $bsa_count > 2: unknown behavior, so defaulting to extra kernel section measurement" >&2
        return 0
    fi
}

# Given a working directory (or $PWD if empty) containing a monotonic counter
# value `counter`; a path to a loader; and a kernel release string (of the form
# returned by uname -r), seals the LUKS passphrase to the loader by predicting
# future PCR values based on the UEFI boot log for the current boot. Will bomb
# out if the system has not been booted from either the primary or old emboot
# boot entry.
seal_and_create_token() {
    local workdir=${1:-.}
    local cryptdev=$2
    local loader=$3
    local krel=$4

    read_efi_vars

    local oldIFS=$IFS
    local IFS=$'\t'
    primary_entry=( ${efi_apps[$(emboot_loader_path | tr a-z A-Z)]} )
    old_entry=( ${efi_apps[$(emboot_loader_path emboot_old.efi | tr a-z A-Z)]} )
    IFS=$oldIFS

    if [[ ${primary_entry[0]} == "$efi_boot_current" ]]; then
        current_loader=${primary_entry[3]}
    elif [[ ${old_entry[0]} == "$efi_boot_current" ]]; then
        current_loader=${old_entry[3]}
    else
        echo "Cannot seal under non-emboot boot chain (BootCurrent=$efi_boot_current)" >&2
        return 1
    fi

    local measurements=( 4 bsa "$loader" )
    if stub_does_extra_pcr_4_measurement; then
        local kernelf=$workdir/kernel.img
        objcopy --dump-section .linux="$kernelf" "$loader"
        measurements+=( 4 bsa "$kernelf" )
    fi

    predict_future_pcrs "$workdir"/pcrs --stop-event bsa-path="${current_loader//\\//}" "${measurements[@]}"
    seal_data "$workdir" <$LUKS_KEY
    import_luks_token "$workdir" "$cryptdev" "$krel"

    evict_efi_vars

    return 0
}

update_efi_entries() {(
    set -e

    read_efi_vars
    local changes=

    for lbn in emboot.efi emboot_old.efi; do
        oldIFS=$IFS; IFS=$'\t'; entry=( ${efi_apps[$(emboot_loader_path "$lbn" | tr a-z A-Z)]} ); IFS=$oldIFS
        if [[ -n "${entry[0]}" ]]; then
            verbose_do -l 1 echo "Existing EFI boot loader entry ${entry[0]} for $lbn"
        else
            tag=$(echo -n "$lbn" | grep '_[^.]' | sed -e 's/^[^_]*_\([^.]\+\).*/\1/')
            echo "Creating EFI boot loader entry for $lbn${tag:+ with tag $tag}"
            create_emboot_efi_entry "$lbn" "$tag"
            changes=1
        fi
    done

    [ -z "$changes" ] || evict_efi_vars

    exit 0
)}

update_efi_boot_order() {(
    set -e

    if is_true "$UPDATE_BOOT_ORDER"; then
        read_efi_vars

        oldIFS=$IFS; IFS=$'\t'
        primary=( ${efi_apps[$(emboot_loader_path "emboot.efi" | tr a-z A-Z)]} )
        old=( ${efi_apps[$(emboot_loader_path "emboot_old.efi" | tr a-z A-Z)]} )
        IFS=$oldIFS
        primary_bn=${primary[0]}
        old_bn=${old[0]}
        if [ -z "$primary_bn" -o -z "$old_bn" ]; then
            echo "Missing emboot EFI boot entries: not updating boot order"
            exit 1
        fi
        if [ "${efi_boot_order[0]}" == "$primary_bn" -a "${efi_boot_order[1]}" == "$old_bn" ]; then
            verbose_do -l 1 echo "No need to update EFI boot order"
            exit 0
        fi
        new_boot_order=( $primary_bn $old_bn )
        for bn in ${efi_boot_order[@]}; do
            if [ "$bn" != "$primary_bn" -a "$bn" != "$old_bn" ]; then
                new_boot_order+=($bn)
            fi
        done
        IFS=','
        echo "Updating EFI boot order to ${new_boot_order[*]}"
        efibootmgr -o "${new_boot_order[*]}"
        OFS=$oldIFS

        evict_efi_vars
    else
        verbose_do -l 1 echo "Updating EFI boot order disabled by config"
    fi

    exit 0
)}

install_loaders() {(
    set -e

    local OPTIND
    local OPTARG
    local krel=
    while getopts 'k:' opt; do
        case "$opt" in
            k) krel=$OPTARG ;;
            :) echo "$OPTARG requires an argument"; exit 1;;
            ?) echo "unknown argument"; exit 1;;
        esac
    done
    shift $((OPTIND-1))

    cleanup() {
        rc=$?
        [ -n "$tmpdir" ] && rm -rf "$tmpdir"
        exit $rc
    }

    trap cleanup EXIT

    tmpdir=$(setup_tmp_dir)

    rootdev=( $(get_device_info /) )
    cryptdev=( $(get_crypttab_entry "${rootdev[1]}") )

    cryptopts=${cryptdev[3]}
    if [[ $cryptopts != *luks* ]]; then
        echo "crypttab entry missing luks option: $cryptopts"
        exit 1
    fi
    if [[ $cryptopts != *keyscript=*emboot_unseal.sh* ]]; then
        echo "keyscript option in crypttab entry missing or invalid: $cryptopts"
        exit 1
    fi

    echo "root=UUID=${rootdev[0]} cryptdevice=${cryptdev[1]}:${cryptdev[0]} $KERNEL_PARAMS" >$tmpdir/kcli.txt

    kernels=( $(list_installed_kernels) )

    set +e

    next_primary=$(kernel_path_to_release "${kernels[0]}")
    next_old=$(kernel_path_to_release "${kernels[1]}")

    for suffix in "" "_old"; do
        loader=$(emboot_loader_unix_path "emboot${suffix}.efi")
        kernel=${kernels[0]}

        if [ -n "$kernel" ]; then
            loader_krel=$(kernel_path_to_release "$kernel")
            initrd=/boot/initrd.img-"$loader_krel"
            kernels=( "${kernels[@]:1}" )

            if [ -z "$krel" -o "$loader_krel" = "$krel" ]; then
                if [ ! -e "$initrd" ]; then
                    echo "Initrd image $initrd for $loader_krel unavailable to create loader $loader"
                    lc_misc rm -f "$loader"
                    if [ -z "$suffix" ]; then
                        echo "WARNING: primary emboot EFI entry is unbootable!"
                    fi
                else
                    printf "%s" "$loader_krel" >$tmpdir/krel.txt
                    echo "Creating EFI loader $loader for $loader_krel"
                    create_loader "$kernel" "$initrd" "$tmpdir"/kcli.txt "$tmpdir"/krel.txt "$tmpdir"/linux.efi
                    lc_misc cp -f "$tmpdir"/linux.efi "$loader"
                    verbose_do -l 1 echo "Removing any existing tokens for $loader_krel"
                    remove_luks_token "${cryptdev[1]}" "$loader_krel"
                fi
            else
                verbose_do -l 1 echo "Skipping creation of EFI loader $loader for $loader_krel"
            fi
        else
            echo "No kernel available to create loader $loader"
            lc_misc rm -f "$loader"
            if [ -z "$suffix" ]; then
                echo "WARNING: primary emboot EFI entry is unbootable!"
            fi
        fi
    done

    exit 0
)}

update_tokens() {(
    set -e

    local OPTIND
    local OPTARG
    local krel=
    local all_kernels=
    while getopts 'k:a' opt; do
        case "$opt" in
            k) krel=$OPTARG ;;
            a) all_kernels=1 ;;
            :) echo "$OPTARG requires an argument"; exit 1;;
            ?) echo "unknown argument"; exit 1;;
        esac
    done
    shift $((OPTIND-1))

    cleanup() {
        rc=$?
        [ -n "$tmpdir" ] && rm -rf "$tmpdir"
        exit $rc
    }

    trap cleanup EXIT

    tmpdir=$(setup_tmp_dir)

    read_efi_vars

    rootdev=( $(get_device_info /) )
    cryptdev=( $(get_crypttab_entry "${rootdev[1]}") )

    for suffix in "" "_old"; do
        loader=$(emboot_loader_unix_path "emboot${suffix}.efi")
        if [ -e "$loader" ]; then
            loader_krel=$(extract_krel_from_loader "$tmpdir" "$loader")
            if [ -n "$loader_krel" ]; then
                token_ids=( $(list_luks_token_ids "${cryptdev[1]}" "$loader_krel") )
                if [ -n "$all_kernels" -o "$krel" = "$loader_krel" -o ${#token_ids} -eq 0 ]; then
                    echo "Creating token for EFI loader $loader for $loader_krel"
                    # Read the counter once for all subsequent seal operations
                    [ -e "$tmpdir"/counter ] || {
                        read_counter "$tmpdir"/counter;
                        if ((EMBOOT_ADD_TO_COUNTER != 0)); then
                            cat "$tmpdir"/counter | xxd -p -c9999;
                            ((curctr=0x$(xxd -p -c9999 <$tmpdir/counter) ));
                            ((sealctr=curctr+$EMBOOT_ADD_TO_COUNTER));
                            printf "%016x" $((sealctr)) | xxd -r -p -c9999 >$tmpdir/counter;
                            printf "Using monotonic counter value %d (=%d+%d)\n" $((sealctr)) $((curctr)) "$EMBOOT_ADD_TO_COUNTER";
                            cat "$tmpdir"/counter | xxd -p -c9999;
                        fi;
                    }
                    seal_and_create_token "$tmpdir" "${cryptdev[1]}" "$loader" "$loader_krel"
                else
                    verbose_do -l 1 echo "Preserving existing token for EFI loader $loader for $loader_krel"
                fi
            else
                echo "Unable to extract kernel release from EFI loader $loader"
                if [ -z "$suffix" ]; then
                    echo "WARNING: primary emboot EFI entry may be unbootable or may require manual passphrase entry!"
                fi
            fi
        else
            echo "EFI loader $loader does not exist"
            if [ -z "$suffix" ]; then
                echo "WARNING: primary emboot EFI entry is unbootable!"
            fi
        fi
    done

    exit 0
)}
