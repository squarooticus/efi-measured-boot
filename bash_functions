#! /bin/bash

buildre() {
    local IFS='|'
    echo "${*//\//\\\/}"
}

quote_args() {
    local sq="'"
    local dq='"'
    local fs=/
    local space=""
    local qw
    local w
    for w; do
        if [ -n "$w" -a -z "${w//[0-9a-zA-Z_,.:=$fs-]}" ]; then
            echo -n "$space$w"
        else
            qw="'${w//$sq/$sq$dq$sq$dq$sq}'"
            qw=${qw//$sq$sq}
            echo -n "$space${qw:-$sq$sq}"
        fi
        space=" "
    done
}

quote_re() {
    echo "$1" | sed -e 's/[]\/\\^$*+?.()|[{}-]/\\\0/g'
}

device_to_disk_and_partition() {
    local dev=$1
    local devpartuuid=$(lsblk -n -o PARTUUID -r "$dev" | tr a-z A-Z)
    local parents=( $(lsblk -s -n -o NAME -r "$dev" | tail -n +2) )
    if (( ${#parents[@]} != 1 )); then
        echo "Don't know how to handle $dev with other than one parent: ${parents[*]}" 1>&2
        exit 1
    fi
    local disk=/dev/${parents[0]}
    local part=$(echo "$dev" | grep -o '[0-9]\+$')
    local checkuuid=$(sgdisk "$disk" -i "$part" | grep -i 'Partition unique GUID' | sed 's/^.*://; s/[[:space:]]\+//g' | tr a-z A-Z)
    if [[ "$devpartuuid" != "$checkuuid" ]]; then
        echo "$dev somehow not $disk partition $part: PARTUUID mismatch ($devpartuuid vs $checkuuid)" 1>&2
        exit 1
    fi
    echo "$disk $part"
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
    if [[ $1 == $2 ]]; then
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
            if [ "${a[i]}" '<' "${b[i]}" ]; then
                return 1
            elif [ "${a[i]}" '>' "${b[i]}" ]; then
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
# compare_versions above.
qsort() {
    local aname=$1
    local compare=$2
    local start=${3:-0}
    local end=${4:-$(( $(eval "echo \${#$aname[@]}") - 1 ))}

    # Algorithm based on Hoare partitioning pseudocode at
    # https://en.wikipedia.org/wiki/Quicksort
    if (( start >= end )); then
        return
    fi
    eval "local pivot=\${$aname[\$start]}"
    local i=$(( start - 1 ))
    local j=$(( end + 1 ))
    local cmpi cmpj
    while true; do
        (( i++ ))
        eval "$compare \"\${$aname[\$i]}\" \"\$pivot\""
        cmpi=$?
        while (( cmpi < 2 )); do
            (( i++ ))
            eval "$compare \"\${$aname[\$i]}\" \"\$pivot\""
            cmpi=$?
        done

        (( j-- ))
        eval "$compare \"\${$aname[\$j]}\" \"\$pivot\""
        cmpj=$?
        while (( cmpj > 2 )); do
            (( j-- ))
            eval "$compare \"\${$aname[\$j]}\" \"\$pivot\""
            cmpj=$?
        done

        if (( i >= j )); then
            break
        fi

        eval "local swap=\${$aname[\$i]}"
        eval "$aname[\$i]=\${$aname[\$j]}"
        eval "$aname[\$j]=\$swap"
    done
    qsort "$aname" "$compare" $start $j
    qsort "$aname" "$compare" $(( j + 1 )) $end
}

# Return a space-delimited list of kernel images in /boot in reverse order
# (highest first).
list_installed_kernels() {
    declare -a kvers
    shopt -s nullglob
    local kvers=( /boot/vmlinuz* )

    kver_descending() {
        local vers=( "${@%%-[^0-9.-]*}" )
        vers=( "${vers[@]##*/vmlinuz-}" )
        compare_versions "${@%%-[^0-9.-]*}"
        local rc=$?
        return $(( 4-rc ))
    }

    qsort kvers kver_descending

    local IFS=" "
    echo "${kvers[*]}"
}

# Populates an associative array `efi_apps` mapping uppercase loader path to a
# tab-separated string with fields (bootnum, display name, partition UUID,
# loader)
read_efi_apps() {
    declare -gA efi_apps
    local IFS=$'\t'
    local loader bootnum desc partuuid
    while read -r loader bootnum desc partuuid; do
        efi_apps[$(echo -n "$loader" | tr a-z A-Z)]="$bootnum"$'\t'"$desc"$'\t'"$partuuid"$'\t'"$loader"
    done < <(efibootmgr -v | grep '^Boot[0-9a-fA-F]\{4\}' | sed -e 's/^Boot\([0-9a-fA-F]\{4\}\)[\* ] \([^\t]\+\)\tHD([0-9]\+,GPT,\([0-9a-fA-F-]\+\),.*File(\([^)]\+\)).*/\4\t\1\t\2\t\3/')
}

create_emboot_efi_entry() {
    local loader_basename=$1
    local suffix=$2
    local efidevinfo=( $("$APPDIR"/get_device_info "$EFI_MOUNT") )
    local efi_disk_and_part=( $(device_to_disk_and_partition "${efidevinfo[1]}") )
    local efidisk=${efi_disk_and_part[0]}
    local efipartition=${efi_disk_and_part[1]}
    local loader="\\EFI\\$OS_SHORT_NAME\\$loader_basename"
    efibootmgr -C -d "${efidisk}" -p "${efipartition}" -l "$loader" -L "${OS_SHORT_NAME} emboot${2:+ ($2)}"
}

seal_to_loader() {
    local workdir=${1:-.}
    local loader=$2
    local krel=$3

    read_efi_apps
    local oldIFS=$IFS; local IFS=$'\t'; primary_entry=( ${efi_apps[$(emboot_loader_path | tr a-z A-Z)]} ); IFS=$oldIFS
    local oldIFS=$IFS; local IFS=$'\t'; old_entry=( ${efi_apps[$(emboot_loader_path emboot_old.efi | tr a-z A-Z)]} ); IFS=$oldIFS

    rm -f "$workdir"/sealed.pub "$workdir"/sealed.priv
    predict_future_pcrs "$workdir" --substitute-bsa-unix-path "$(efi_path_to_unix "${primary_entry[3]}")=$loader" --substitute-bsa-unix-path "$(efi_path_to_unix "${old_entry[3]}")=$loader"
    seal_data "$workdir" <$LUKS_KEY
    mkdir -p $(emboot_state_path "$krel")
    cp -f "$workdir"/counter "$workdir"/sealed.pub "$workdir"/sealed.priv "$(emboot_state_path "$krel")/"
}
