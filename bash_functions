#! /bin/bash

buildre() {
    local IFS='|'
    echo "${*//\//\\\/}"
}

quote_args() {
    sq="'"
    dq='"'
    fs=/
    space=""
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
    dev=$1
    devpartuuid=$(lsblk -n -o PARTUUID -r "$dev" | tr a-z A-Z)
    parents=( $(lsblk -s -n -o NAME -r "$dev" | tail -n +2) )
    if (( ${#parents[@]} != 1 )); then
        echo "Don't know how to handle $dev with other than one parent: ${parents[*]}" 1>&2
        exit 1
    fi
    disk=/dev/${parents[0]}
    part=$(echo "$dev" | grep -o '[0-9]\+$')
    checkuuid=$(sgdisk "$disk" -i "$part" | grep -i 'Partition unique GUID' | sed 's/^.*://; s/[[:space:]]\+//g' | tr a-z A-Z)
    if [[ "$devpartuuid" != "$checkuuid" ]]; then
        echo "$dev somehow not $disk partition $part: PARTUUID mismatch ($devpartuuid vs $checkuuid)" 1>&2
        exit 1
    fi
    echo "$disk $part"
}

# Compares two tuple-based, dot-delimited version numbers a and b (possibly
# with arbitrary string suffixes). Compatible with semantic versioning, but not
# as strict: comparisons of non-semver strings are undefined.
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

    # Compare numeric release versions. Supports arbitrary tuple size (not just
    # X.Y.Z)
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
