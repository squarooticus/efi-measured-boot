#! /bin/bash

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

quote_bre() {
    echo "$1" | sed -e 's/[]\\^$*.[]/\\\0/g'
}

any_of_bre() {
    quoted=""
    oor=""
    for w; do
        quoted=$quoted$oor$(quote_bre "$w")
        oor='\|'
    done
    echo "$quoted"
}

parse_yaml() {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
       -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
       -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" $1 | \
       awk -F$fs '{
          indent = length($1)/2;
          vname[indent] = $2;
          for (i in vname) {if (i > indent) {delete vname[i]}}
              if (length($3) > 0) {
                  vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
                  printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
              }
          }'
}

provision_counter() {
    if tpm2_nvreadpublic -Q "$COUNTER_HANDLE" 2>/dev/null; then
        eval "$(tpm2_nvreadpublic "$COUNTER_HANDLE" | parse_yaml '' nvmd_)"
        invar=nvmd_$(printf "0x%x" $COUNTER_HANDLE)_attributes_value
        if [ -z "${!invar}" ]; then
            echo "Cannot parse attributes for NV index $COUNTER_HANDLE" 1>&2
            return 1
        elif [[ ${!invar} != "0x12000222" ]]; then
            echo "Conflicting counter with invalid attributes at NV index $COUNTER_HANDLE" 1>&2
            return 1
        fi
        echo "Using existing counter at NV index $COUNTER_HANDLE" 1>&2
    else
        if ! tpm2_nvdefine "$COUNTER_HANDLE" -C o -s 8 -a 'ownerread|ownerwrite|no_da|nt=counter'; then
            echo "Unable to create counter at NV index $COUNTER_HANDLE" 1>&2
            return 1
        fi
    fi
    tpm2_nvincrement -C o "$COUNTER_HANDLE" && tpm2_shutdown
}

device_to_disk_and_partition() {
    local dev=$1
    local devpartuuid=$(lsblk -n -o PARTUUID -r "$dev" | tr a-z A-Z)
    local parents=( $(lsblk -s -n -o NAME -r "$dev" | tail -n +2) )
    if (( ${#parents[@]} != 1 )); then
        echo "Do not know how to handle $dev with other than one parent: ${parents[*]}" 1>&2
        return 1
    fi
    local disk=/dev/${parents[0]}
    local part=$(echo "$dev" | grep -o '[0-9]\+$')
    local checkuuid=$(sgdisk "$disk" -i "$part" | grep -i 'Partition unique GUID' | sed 's/^.*://; s/[[:space:]]\+//g' | tr a-z A-Z)
    if [[ $devpartuuid != "$checkuuid" ]]; then
        echo "$dev somehow not $disk partition $part: PARTUUID mismatch ($devpartuuid vs $checkuuid)" 1>&2
        return 1
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

get_crypttab_entry() (
    local cmd=$0
    local devnode=$1

    set -e

    local parentdevices=( $(lsblk -s -t $devnode -o UUID -n -r | grep '.' | sort | uniq) )
    local parentdevicenodes=( $(lsblk -p -s -t $devnode -o NAME -n -r | grep '.' | sort | uniq) )
    local OLDIFS=$IFS
    local IFS=$'\n'
    local crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep 'UUID=\('"$(any_of_bre "${parentdevices[@]}")"'\)' || true) )
    if (( ${#crypttabentries[@]} == 0 )); then
        echo 'crypttab entry not found via UUID; trying node' 1>&2
        crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep "$(any_of_bre "${parentdevicenodes[@]}")" || true) )
    fi
    IFS=$OLDIFS
    if (( ${#crypttabentries[@]} == 0 )); then
        echo 'crypttab entry not found' 1>&2
        exit 1
    fi
    if (( ${#crypttabentries[@]} > 1 )); then
        echo 'filesystem in multiple crypttab entries unsupported' 1>&2
        IFS=$'\n'; echo "${crypttabentries[*]}"
        exit 1
    fi
    local cryptdev=( ${crypttabentries[0]} )

    IFS=' '
    echo "${cryptdev[*]}"
)

get_device_info() (
    local cmd=$0
    local trace_path=${1:-/}

    set -e

    local mount_point=$(stat -c '%m' $trace_path)

    local dev=( $(lsblk -n -o UUID,PATH,MOUNTPOINT -r | awk '$3 == "'"$mount_point"'" { print $1 " " $2; }') )
    if (( ${#dev[@]} == 0 )); then
        echo "no block device found with mount point $mount_point" 1>&2
        exit 1
    fi

    echo "${dev[0]} ${dev[1]}"
)

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
read_efi_vars() {
    declare -gA efi_apps; efi_apps=()
    local IFS=$'\t'
    local loader bootnum desc partuuid
    while read -r loader bootnum desc partuuid; do
        efi_apps[$(echo -n "$loader" | tr a-z A-Z)]="$bootnum"$'\t'"$desc"$'\t'"$partuuid"$'\t'"$loader"
    done < <(efibootmgr -v | grep '^Boot[0-9a-fA-F]\{4\}' | sed -e 's/^Boot\([0-9a-fA-F]\{4\}\)[\* ] \([^\t]\+\)\tHD([0-9]\+,GPT,\([0-9a-fA-F-]\+\),.*File(\([^)]\+\)).*/\4\t\1\t\2\t\3/')
    declare -ga efi_boot_order
    local IFS=','
    efi_boot_order=( $(efibootmgr -v | grep '^BootOrder' | sed -e 's/^BootOrder: *//') )
    efi_boot_current=$(efibootmgr -v | grep '^BootCurrent' | sed -e 's/^BootCurrent: *//')
}

create_emboot_efi_entry() {
    local loader_basename=$1
    local suffix=$2
    local efidevinfo=( $("$APPDIR"/get_device_info "$EFI_MOUNT") )
    local efi_disk_and_part=( $(device_to_disk_and_partition "${efidevinfo[1]}") )
    local efidisk=${efi_disk_and_part[0]}
    local efipartition=${efi_disk_and_part[1]}
    local loader="\\EFI\\$OS_SHORT_NAME\\$loader_basename"
    efibootmgr -C -d "$efidisk" -p "$efipartition" -l "$loader" -L "$OS_SHORT_NAME emboot${suffix:+ ($suffix)}"
}

seal_to_loader() {
    local workdir=${1:-.}
    local loader=$2
    local krel=$3

    read_efi_vars
    local oldIFS=$IFS; local IFS=$'\t'; primary_entry=( ${efi_apps[$(emboot_loader_path | tr a-z A-Z)]} ); IFS=$oldIFS
    local oldIFS=$IFS; local IFS=$'\t'; old_entry=( ${efi_apps[$(emboot_loader_path emboot_old.efi | tr a-z A-Z)]} ); IFS=$oldIFS

    if [[ ${primary_entry[0]} == "$efi_boot_current" ]]; then
        current_loader=${primary_entry[3]}
    elif [[ ${old_entry[0]} == "$efi_boot_current" ]]; then
        current_loader=${old_entry[3]}
    else
        echo "Cannot seal under non-emboot boot chain (BootCurrent=$efi_boot_current)" 1>&2
        return 1
    fi

    rm -f "$workdir"/sealed.pub "$workdir"/sealed.priv
    predict_future_pcrs "$workdir" --substitute-bsa-unix-path "$(efi_path_to_unix "$current_loader")=$loader"
    seal_data "$workdir" <$LUKS_KEY
    mkdir -p $(emboot_state_path "$krel")
    cp -f "$workdir"/counter "$workdir"/sealed.pub "$workdir"/sealed.priv "$(emboot_state_path "$krel")/"
}
