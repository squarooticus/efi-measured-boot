#! /bin/bash

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
    if (( ${#a[@]} < ${#b[@]} )); then
        return 1
    elif (( ${#a[@]} > ${#b[@]} )); then
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
    local end=${4:-$(( ${#aref[@]} - 1 ))}

    # Algorithm based on Hoare partitioning pseudocode at
    # https://en.wikipedia.org/wiki/Quicksort
    if (( start >= end )); then
        return
    fi
    local pivot=${aref[$start]}
    local i=$(( start - 1 ))
    local j=$(( end + 1 ))
    local cmpi cmpj
    while true; do
        (( i++ ))
        $compare "${aref[$i]}" "$pivot"
        cmpi=$?
        while (( cmpi < 2 )); do
            (( i++ ))
            $compare "${aref[$i]}" "$pivot"
            cmpi=$?
        done
        if (( cmpi == 4 )); then return 4; fi

        (( j-- ))
        $compare "${aref[$j]}" "$pivot"
        cmpj=$?
        while (( cmpj > 2 && cmpj != 4 )); do
            (( j-- ))
            $compare "${aref[$j]}" "$pivot"
            cmpj=$?
        done
        if (( cmpi == 4 )); then return 4; fi

        if (( i >= j )); then
            break
        fi

        local swap=${aref[$i]}
        aref[$i]=${aref[$j]}
        aref[$j]=$swap
    done
    qsort "$aname" "$compare" $start $j
    qsort "$aname" "$compare" $(( j + 1 )) $end
}

# Provisions the monotonic counter used to prevent downgrade attacks, unless
# one with the correct properties already exists. Errors if the NV handle is in
# use with conflicting properties.
provision_counter() {
    if tpm2_nvreadpublic -Q "$COUNTER_HANDLE" 2>/dev/null; then
        eval "$(tpm2_nvreadpublic "$COUNTER_HANDLE" | parse_yaml '' nvmd_)"
        invar=nvmd_$(printf "0x%x" $COUNTER_HANDLE)_attributes_value
        if [ -z "${!invar}" ]; then
            echo "Cannot parse attributes for NV index $COUNTER_HANDLE" >&2
            return 1
        elif [[ ${!invar} != "0x12000222" ]]; then
            echo "Conflicting counter with invalid attributes at NV index $COUNTER_HANDLE" >&2
            return 1
        fi
        echo "Using existing counter at NV index $COUNTER_HANDLE" >&2
    else
        if ! tpm2_nvdefine "$COUNTER_HANDLE" -C o -s 8 -a 'ownerread|ownerwrite|no_da|nt=counter'; then
            echo "Unable to create counter at NV index $COUNTER_HANDLE" >&2
            return 1
        fi
    fi
    tpm2_nvincrement -C o "$COUNTER_HANDLE" && tpm2_shutdown
}

# Given a device node, returns the disk node and partition number. Sanity
# checks that the partition UUID of the input and output match.
device_to_disk_and_partition() {
    local dev=$1
    local devpartuuid=$(lsblk -n -o PARTUUID -r "$dev" | tr a-z A-Z)
    local parents=( $(lsblk -s -n -o NAME -r "$dev" | tail -n +2) )
    if (( ${#parents[@]} != 1 )); then
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
    local cmd=$0
    local devnode=$1

    set -e

    local parentdevices=( $(lsblk -s -t $devnode -o UUID -n -r | grep '.' | sort | uniq) )
    local OLDIFS=$IFS
    local IFS=$'\n'
    local crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep 'UUID=\('"$(any_of_bre "${parentdevices[@]}")"'\)' || true) )
    if (( ${#parentdevices[@]} == 0 || ${#crypttabentries[@]} == 0 )); then
        echo 'crypttab entry not found via UUID; trying node' >&2
        IFS=$OLDIFS
        local parentdevices=( $(lsblk -p -s -t $devnode -o NAME -n -r | grep '.' | sort | uniq) )
        IFS=$'\n'
        crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep "$(any_of_bre "${parentdevices[@]}")" || true) )
    fi
    IFS=$OLDIFS
    if (( ${#parentdevices[@]} == 0 || ${#crypttabentries[@]} == 0 )); then
        echo 'crypttab entry not found' >&2
        exit 1
    fi
    if (( ${#crypttabentries[@]} > 1 )); then
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
    local cmd=$0
    local trace_path=${1:-/}

    set -e

    local mount_point=$(stat -c '%m' $trace_path)

    local dev=( $(lsblk -n -o UUID,PATH,MOUNTPOINT -r | awk '$3 == "'"$mount_point"'" { print $1 " " $2; }') )
    if (( ${#dev[@]} == 0 )); then
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
        if (( ${#vers[@]} != 2 )); then return 4; fi
        compare_versions "${vers[@]}"
        local rc=$?
        return $(( 4-rc ))
    }

    qsort kvers kver_descending
    if (( $? == 4 )); then return 1; fi

    local IFS=" "
    printf %s "${kvers[*]}"
)}

# Populates:
#  * An associative array `efi_apps` mapping uppercase loader path to a
#  tab-separated string with fields (bootnum, display name, partition UUID,
#  loader)
#  * An array `efi_boot_order` containing the boot order (each element of which
#  is 4 hex digits)
#  * A string `efi_boot_current` containing the current boot entry (also 4 hex
#  digits)
read_efi_vars() {
    declare -gA efi_apps; efi_apps=()
    local IFS=$'\t'
    local loader bootnum desc partuuid
    while read -r loader bootnum desc partuuid; do
        efi_apps[$(printf %s "$loader" | tr a-z A-Z)]="$bootnum"$'\t'"$desc"$'\t'"$partuuid"$'\t'"$loader"
    done < <(efibootmgr -v | grep '^Boot[0-9a-fA-F]\{4\}' | sed -e 's/^Boot\([0-9a-fA-F]\{4\}\)[\* ] \([^\t]\+\)\tHD([0-9]\+,GPT,\([0-9a-fA-F-]\+\),.*File(\([^)]\+\)).*/\4\t\1\t\2\t\3/')
    declare -ga efi_boot_order
    local IFS=','
    efi_boot_order=( $(efibootmgr -v | grep '^BootOrder' | sed -e 's/^BootOrder: *//') )
    efi_boot_current=$(efibootmgr -v | grep '^BootCurrent' | sed -e 's/^BootCurrent: *//')
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
    efibootmgr -C -d "$efidisk" -p "$efipartition" -l "$loader" -L "$OS_SHORT_NAME emboot${tag:+ ($tag)}"
}

# Outputs the index of the emboot key slot. If there is an existing emboot
# token, pulls this directly from the emboot metadata; if not, tests the key
# against all keyslots until it finds a match.
get_emboot_key_slot() {
    local cryptdev=$1
    local emboot_token_ids=( $(list_luks_token_ids "$cryptdev") )
    if (( ${#emboot_token_ids[@]} > 0 )); then
        local one_token_id=${emboot_token_ids[0]}
        local first_keyslot=$(cryptsetup luksDump "$cryptdev" --dump-json-metadata | jq -j '.tokens."'"$one_token_id"'".keyslots | first')
        if [ -n "$first_keyslot" -a "$first_keyslot" != "null" ]; then
            printf %s "$first_keyslot"
            return 0
        fi
    fi
    local keyslots=( $(cryptsetup luksDump "$cryptdev" --dump-json-metadata | jq -j '.keyslots | keys | join(" ")') )
    local i
    for i in "${keyslots[@]}"; do
        if </dev/null cryptsetup luksOpen --test-passphrase -d "$LUKS_KEY" --key-slot "$i" "$cryptdev" >/dev/null 2>&1; then
            printf %s "$i"
            return 0
        fi
    done
    return 1
}

# Composes emboot seal metadata from the working directory and imports it as a
# new LUKS token.
import_luks_seal_metadata() {
    local workdir=${1:-.}
    local cryptdev=$2
    local krel=$3
    declare -a args
    local json=''
    local k
    for k in counter pcrs sealed.priv sealed.pub; do
        <$workdir/$k b64encode -w 0 >$workdir/$k.b64
        args+=( --rawfile "${k//./_}" "$workdir/$k.b64" )
        json+=", \"$k\": \$${k//./_}"
    done
    local keyslot=$(get_emboot_key_slot "$cryptdev")
    [ -n "$keyslot" ] || {
        echo "No key slots on $cryptdev matching $LUKS_KEY" >&2
        return 1
    }
    jq --null-input "${args[@]}" --arg krel "$krel" --arg keyslot "$keyslot" --arg updated "$(date +%s)" '{ "type": "emboot", "keyslots": [ $keyslot ], "krel": $krel, "updated": $updated'"$json"' }' >"$workdir"/token.json
    local current_token_ids=( $(list_luks_token_ids "$cryptdev" "$krel") )
    for k in "${current_token_ids[@]}"; do
        cryptsetup token remove "$cryptdev" --token-id "$k"
    done
    cryptsetup token import "$cryptdev" --json-file "$workdir"/token.json
}

# Given a working directory (or $PWD if empty), a path to a loader, and a
# kernel release string (of the form returned by uname -r), seals the LUKS
# passphrase to the loader by predicting future PCR values based on the UEFI
# boot log for the current boot. Will bomb out if the system has not been
# booted from either the primary or old emboot boot entry.
seal_to_loader() {
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

    predict_future_pcrs "$workdir" --substitute-bsa-unix-path "$(efi_path_to_unix "$current_loader")=$loader"
    seal_data "$workdir" <$LUKS_KEY
    import_luks_seal_metadata "$workdir" "$cryptdev" "$krel"
}
