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
