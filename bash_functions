#! /bin/bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Kyle R. Rose

. "$EMBOOT_SHARE/functions"

# Shell quotes with an attempt to make the result human-readable.
quote_args() {
    local sq=\'
    local dq=\"
    local fs=/
    local space=''
    local qw
    local w
    for w; do
        if [ -n "$w" -a -z "${w//[0-9a-zA-Z_,.:=$fs-]}" ]; then
            printf %s "$space$w"
        else
            qw=$sq${w//$sq/$sq$dq$sq$dq$sq}$sq
            qw=${qw//$sq$sq}
            printf %s "$space${qw:-$sq$sq}"
        fi
        space=" "
    done
}

# Provisions the monotonic counter used to prevent downgrade attacks, unless
# one with the correct properties already exists. Errors if the NV handle is in
# use with conflicting properties.
provision_counter() {
    if lc_tpm tpm2_nvreadpublic "$COUNTER_HANDLE" >/dev/null; then
        eval "$(lc_tpm tpm2_nvreadpublic "$COUNTER_HANDLE" | parse_yaml '' nvmd_)"
        local invar=nvmd_$(printf 0x%x $COUNTER_HANDLE)_attributes_value
        if [ -z "${!invar}" ]; then
            log_fatal -t tpm 'Cannot parse attributes for NV index %s' "$COUNTER_HANDLE"
            return 1
        fi
        declare -i attrs=${!invar}
        if (( (attrs & 0x20200f2) != 0x2020012 )); then
            log_fatal -t tpm 'Conflicting counter with invalid attributes at NV index %s (value=%s)' "$COUNTER_HANDLE" "$attrs"
            return 1
        fi
        log_info -t tpm 'Using existing counter at NV index %s' "$COUNTER_HANDLE"
    else
        if ! lc_tpm tpm2_nvdefine "$COUNTER_HANDLE" -C o -s 8 -a 'ownerread|ownerwrite|no_da|nt=counter'; then
            log_fatal -t tpm 'Unable to create counter at NV index %s' "$COUNTER_HANDLE"
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
        log_fatal -t dev 'Do not know how to handle %s with other than one parent: %s' "$dev" "${parents[*]}"
        return 1
    fi
    local disk=/dev/${parents[0]}
    local part=$(printf %s "$dev" | grep -o '[0-9]\+$')
    local checkuuid=$(sgdisk "$disk" -i "$part" | grep -i 'Partition unique GUID' | sed 's/^.*://; s/[[:space:]]\+//g' | tr a-z A-Z)
    if [[ $devpartuuid != "$checkuuid" ]]; then
        log_fatal -t dev 'PARTUUID mismatch: %s (%s) somehow not %s partition %s (%s)' "$dev" "$devpartuuid" "$disk" "$part" "$checkuuid"
        return 1
    fi
    printf %s "$disk $part"
}

# Given a device node, output the unique entry from /etc/crypttab covering that
# device (e.g., containing that partition or LVM logical volume or whatever).
get_crypttab_entry() {(
    local devnode=$1

    set -e

    local crypt_count
    crypt_count=$(lsblk -s "$devnode" -o TYPE -n -r | grep -c '^crypt$' || true)
    if ((crypt_count > 1)); then
        log_error -t luks \
            'Root device has %d independent dm-crypt layers; only a single LUKS device is supported' \
            "$crypt_count"
        exit 1
    fi

    local parentdevices=( $(lsblk -s $devnode -o UUID -n -r | grep '.' | sort | uniq) )
    local OLDIFS=$IFS
    local IFS=$'\n'
    local crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep 'UUID=\('"$(any_of_bre "${parentdevices[@]}")"'\)' || true) )
    if ((${#parentdevices[@]} == 0 || ${#crypttabentries[@]} == 0)); then
        log_warn -t luks 'crypttab entry not found via UUID; trying node'
        IFS=$OLDIFS
        local parentdevices=( $(lsblk -p -s $devnode -o NAME -n -r | grep '.' | sort | uniq) )
        IFS=$'\n'
        crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep "$(any_of_bre "${parentdevices[@]}")" || true) )
    fi
    IFS=$OLDIFS
    if ((${#parentdevices[@]} == 0 || ${#crypttabentries[@]} == 0)); then
        log_error -t luks 'crypttab entry not found'
        exit 1
    fi
    if ((${#crypttabentries[@]} > 1)); then
        log_error -t luks 'Filesystem in multiple crypttab entries unsupported'
        for cte in "${crypttabentries[@]}"; do
            log_error -t luks '%s' "$cte"
        done
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

    local result
    result=$(findmnt -n -o UUID,SOURCE -T "$trace_path") || {
        log_error -t dev 'No block device found for path %s' "$trace_path"
        exit 1
    }
    printf %s "$result"
)}

# Output a space-separated list of kernel images in /boot in reverse order
# (highest version first).
list_installed_kernels() {(
    declare -A ver_to_file
    while read -r kver kimgf; do
        ver_to_file[$kver]=$kimgf
    done < <( linux-version list --paths )

    declare -a newest_first=( $( linux-version sort --reverse $(linux-version list) ) )

    space=
    for v in "${newest_first[@]}"; do
        printf "%s%s" "$space" "${ver_to_file[$v]}"
        space=' '
    done
)}

# GUID for the standard EFI global variable namespace, where Boot####,
# BootOrder, and BootCurrent live.
EFI_GLOBAL_VARS_GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c

# Fetches the raw value of the given EFI variable (in "GUID-Name" form, as
# produced by `efivar -l`) and flattens efivar's od-style hex dump (an
# 8-digit offset column, two groups of 8 space-separated hex byte pairs, and
# an ASCII rendering in |...|) down to one contiguous lowercase hex string
# (two hex characters per byte, no separators). Outputs the empty string if
# the variable does not exist or efivar fails for any other reason (e.g.
# non-UEFI system, insufficient permissions); callers must treat an
# empty/too-short result as "value unavailable", not an error.
efi_var_hex() {
    local varname=$1
    lc_efi -Q efivar -p -n "$varname" | lc_misc gawk '
        /^[0-9a-fA-F]{8} / {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9a-fA-F][0-9a-fA-F]$/) printf "%s", $i
            }
        }'
}

# Extracts a little-endian unsigned integer from a flat hex string (as
# produced by efi_var_hex), given a byte offset and byte length, and prints
# it in decimal. Out-of-range access (offset/length past the end of the
# string) yields 0 rather than erroring; callers are expected to have
# already range-checked against the declared length of the structure being
# parsed before calling this.
efi_hex_le_uint() {
    local hex=$1 off=$2 len=$3
    local i swapped=''
    for (( i = len - 1; i >= 0; i-- )); do
        swapped+=${hex:$(( (off + i) * 2 )):2}
    done
    printf '%d' "$((16#${swapped:-0}))"
}

# Decodes a null-terminated UCS-2 string (assumed ASCII-range: only the low
# byte of each 2-byte code unit is used, matching every real description and
# loader path in practice) starting at the given byte offset in a flat hex
# string. Stops at the first null code unit, or at the optional byte-offset
# `limit` (exclusive) if given, or at the physical end of the hex string,
# whichever comes first.
#
# Since bash functions cannot cleanly return two values, this sets two
# globals instead of using stdout: `efi_ucs2_str` (the decoded string, ASCII)
# and `efi_ucs2_bytelen` (bytes consumed, including the 2-byte null
# terminator if one was found).
#
# Returns 0 if a genuine null terminator was found before the limit/end of
# string; returns 1 (data considered malformed/truncated) otherwise, with
# `efi_ucs2_str`/`efi_ucs2_bytelen` reflecting whatever was decoded up to
# that point.
efi_hex_decode_ucs2() {
    local hex=$1 off=$2 limit=${3:-$((${#hex} / 2))}
    local i=0 lo hi escapes=''
    while (( off + i < limit )); do
        lo=${hex:$(( (off + i) * 2 )):2}
        hi=${hex:$(( (off + i + 1) * 2 )):2}
        if [[ -z $lo || ( $lo == 00 && $hi == 00 ) ]]; then
            i=$((i + 2))
            efi_ucs2_str=$(printf "${escapes:-}")
            efi_ucs2_bytelen=$i
            [[ $lo == 00 && $hi == 00 ]]
            return
        fi
        escapes+="\\x$lo"
        i=$((i + 2))
    done
    efi_ucs2_str=$(printf "${escapes:-}")
    efi_ucs2_bytelen=$i
    return 1
}

# Formats the 16 raw bytes at the given byte offset in a flat hex string as a
# standard mixed-endian GUID string, matching efibootmgr's / the UEFI
# spec's display convention (the first 8 bytes -- a UINT32 and two UINT16s --
# are byte-swapped to little-endian display order; the last 8 bytes are
# printed as-is).
efi_hex_format_guid() {
    local hex=$1 off=$2
    local -a b
    local j
    for (( j = 0; j < 16; j++ )); do
        b[j]=${hex:$(( (off + j) * 2 )):2}
    done
    printf '%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s' \
        "${b[3]}" "${b[2]}" "${b[1]}" "${b[0]}" \
        "${b[5]}" "${b[4]}" \
        "${b[7]}" "${b[6]}" \
        "${b[8]}" "${b[9]}" \
        "${b[10]}" "${b[11]}" "${b[12]}" "${b[13]}" "${b[14]}" "${b[15]}"
}

# Parses the raw hex value of a Boot#### EFI_LOAD_OPTION variable (as
# produced by efi_var_hex) into its description, partition UUID, and loader
# path, per the UEFI EFI_LOAD_OPTION structure:
#
#   offset 0: Attributes (UINT32 LE)
#   offset 4: FilePathListLength (UINT16 LE)
#   offset 6: Description (null-terminated CHAR16[])
#   offset 6+desclen: FilePathList (UINT8[FilePathListLength]): a TLV chain
#     of device-path nodes terminated by an END_ENTIRE_DEVICE_PATH node
#   offset 6+desclen+FilePathListLength: OptionalData (ignored -- this is
#     exactly the ambiguous, vendor-specific tail that efibootmgr's text
#     rendering cannot reliably separate from the loader path, especially on
#     newer libefivar versions that drop the "File(...)" wrapper entirely)
#
# Walks the FilePathList looking for a HARDDRIVE_DP node (for the partition
# GUID) and a MEDIA_FILEPATH_DP node (for the loader path), skipping over any
# other node type by advancing past its length field (handles PCI/ACPI nodes
# that may precede the HD node on real hardware; does not assume "HD then
# File" is the only possible sequence).
#
# On success, sets globals `efi_parsed_desc`, `efi_parsed_partuuid`,
# `efi_parsed_loader` and returns 0. On any parse failure -- entry too
# short, FilePathListLength pointing past the end of the value, a malformed
# (too-short) TLV node length, a description/loader string that never hits a
# null terminator, or a device path missing an HD or FILE_PATH node -- logs
# a warning (identifying the entry by `bootnum_for_log`) and returns 1
# without touching the output globals. Entries that fail to parse are
# skipped by the caller rather than added to `efi_apps` in some
# partially-parsed state.
efi_parse_boot_entry() {
    local bootnum_for_log=$1 hex=$2
    local total=$(( ${#hex} / 2 ))

    if (( total < 6 )); then
        log_warn -t efi 'Skipping Boot%s: value too short (%d bytes)' "$bootnum_for_log" "$total"
        return 1
    fi

    local fplen=$(efi_hex_le_uint "$hex" 4 2)
    efi_hex_decode_ucs2 "$hex" 6 "$total" || {
        log_warn -t efi 'Skipping Boot%s: description string not null-terminated' "$bootnum_for_log"
        return 1
    }
    local desc=$efi_ucs2_str
    local fp_start=$((6 + efi_ucs2_bytelen))
    local fp_end=$((fp_start + fplen))

    if (( fp_end > total )); then
        log_warn -t efi 'Skipping Boot%s: FilePathListLength (%d) extends past end of value' "$bootnum_for_log" "$fplen"
        return 1
    fi

    local off=$fp_start found_hd= found_file= loader= partuuid=
    while (( off + 4 <= fp_end )); do
        local dp_type=$(efi_hex_le_uint "$hex" $off 1)
        local dp_subtype=$(efi_hex_le_uint "$hex" $((off + 1)) 1)
        local dp_len=$(efi_hex_le_uint "$hex" $((off + 2)) 2)

        if (( dp_len < 4 )); then
            log_warn -t efi 'Skipping Boot%s: malformed device-path node length (%d) at offset %d' "$bootnum_for_log" "$dp_len" "$off"
            return 1
        fi
        if (( dp_type == 0x7f && dp_subtype == 0xff )); then
            break  # END_ENTIRE_DEVICE_PATH
        fi
        if (( dp_type == 0x04 && dp_subtype == 0x01 )); then
            # MEDIA_DEVICE_PATH / HARDDRIVE_DP (fixed 42-byte node): 16-byte
            # partition GUID starts 24 bytes in (4-byte TLV header + 20
            # bytes of PartitionNumber/Start/Size).
            partuuid=$(efi_hex_format_guid "$hex" $((off + 4 + 20)))
            found_hd=1
        elif (( dp_type == 0x04 && dp_subtype == 0x04 )); then
            # MEDIA_DEVICE_PATH / MEDIA_FILEPATH_DP: null-terminated
            # CHAR16[] loader path starts right after the 4-byte TLV header,
            # bounded by this node's own length.
            efi_hex_decode_ucs2 "$hex" $((off + 4)) $((off + dp_len)) || {
                log_warn -t efi 'Skipping Boot%s: loader path not null-terminated' "$bootnum_for_log"
                return 1
            }
            loader=$efi_ucs2_str
            found_file=1
        fi
        off=$((off + dp_len))
    done

    if [[ -z $found_hd ]]; then
        log_warn -t efi 'Skipping Boot%s: no HARDDRIVE device-path node found' "$bootnum_for_log"
        return 1
    fi
    if [[ -z $found_file ]]; then
        log_warn -t efi 'Skipping Boot%s: no FILE_PATH device-path node found' "$bootnum_for_log"
        return 1
    fi

    efi_parsed_desc=$desc
    efi_parsed_partuuid=$partuuid
    efi_parsed_loader=$loader
    return 0
}

# Populates:
#
#   - An associative array `efi_apps` mapping uppercase loader path to a
#   tab-separated string with fields (bootnum, display name, partition UUID,
#   loader)
#
#   - An array `efi_boot_order` containing the boot order (each element of
#   which is 4 uppercase hex digits)
#
#   - A string `efi_boot_current` containing the current boot entry (also 4
#   uppercase hex digits)
#
# Reads directly from the raw EFI_LOAD_OPTION / BootOrder / BootCurrent
# variable values via `efivar`, rather than parsing efibootmgr's text
# output, to unambiguously separate a loader's device path from trailing
# vendor-specific optional data (which efibootmgr -v's text rendering glues
# onto the path with no delimiter when non-printable -- and on newer
# libefivar versions, drops the "File(...)" wrapper entirely, removing even
# the closing-paren heuristic).
#
# Caches the result. Use `evict_efi_vars` to evict this cache if the EFI vars
# are known to have changed.
read_efi_vars() {
    if [ -z "$efi_vars_available" ]; then
        declare -gA efi_apps=()
        declare -ga efi_boot_order=()
        declare -g efi_boot_current=

        local name bootnum hex
        while read -r -u 3 name; do
            bootnum=$(printf %s "${name#$EFI_GLOBAL_VARS_GUID-Boot}" | tr a-z A-Z)
            hex=$(efi_var_hex "$name")
            efi_parse_boot_entry "$bootnum" "$hex" || continue
            log_debug -t efi 'reading EFI entry %s: desc=%s partuuid=%s loader=%s' \
                "$bootnum" "$efi_parsed_desc" "$efi_parsed_partuuid" "$efi_parsed_loader"
            efi_apps[$(printf %s "$efi_parsed_loader" | tr a-z A-Z)]=$bootnum$'\t'$efi_parsed_desc$'\t'$efi_parsed_partuuid$'\t'$efi_parsed_loader
        done 3< <(lc_efi -Q efivar -l | lc_misc grep '^'"$EFI_GLOBAL_VARS_GUID"'-Boot[0-9a-fA-F]\{4\}$' || true) </dev/null

        hex=$(efi_var_hex "$EFI_GLOBAL_VARS_GUID-BootOrder")
        if [ -n "$hex" ]; then
            local n=$(( ${#hex} / 4 ))
            local i v
            for (( i = 0; i < n; i++ )); do
                v=$(efi_hex_le_uint "$hex" $((i * 2)) 2)
                efi_boot_order+=( "$(printf '%04X' "$v")" )
            done
        fi
        log_debug -t efi 'EFI boot order: %s' "${efi_boot_order[*]}"

        hex=$(efi_var_hex "$EFI_GLOBAL_VARS_GUID-BootCurrent")
        if [ -n "$hex" ]; then
            efi_boot_current=$(printf '%04X' "$(efi_hex_le_uint "$hex" 0 2)")
        fi
        log_debug -t efi 'EFI boot current: %s' "$efi_boot_current"

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
    local loader=\\EFI\\$OS_SHORT_NAME\\$loader_basename
    lc_efi -Q efibootmgr -C -d "$efidisk" -p "$efipartition" -l "$loader" -L "$OS_SHORT_NAME emboot${tag:+ ($tag)}"
}

# Given a crypto device, populates `luksmd` with the output of dumping the LUKS
# metadata for the crypto device in JSON format.
read_luks_metadata() {
    local cryptdev=$1
    declare -gA luksmd
    [ -n "${luksmd[$cryptdev]}" ] || luksmd[$cryptdev]=$(lc_luks cryptsetup luksDump "$cryptdev" --dump-json-metadata)
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
    printf %s "${luksmd[$cryptdev]:-$(lc_luks cryptsetup luksDump "$cryptdev" --dump-json-metadata)}" | lc_misc jq -j '."tokens" | to_entries | map(select(."value"."type" == "emboot"'"${krel:+ and .\"value\".\"krel\" == \"$krel\"}"')) | map(.key) | sort | join(" ")'
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
        first_keyslot=$(printf %s "${luksmd[$cryptdev]}" | lc_misc jq -j '.tokens."'"$one_token_id"'".keyslots | first')
        if [ -n "$first_keyslot" -a "$first_keyslot" != "null" ]; then
            if lc_luks -Q cryptsetup luksOpen --test-passphrase -d "$LUKS_KEY" --key-slot "$first_keyslot" "$cryptdev" </dev/null >/dev/null; then
                log_info -t luks 'Passphrase found in keyslot %s (from token %s)' "$first_keyslot" "$one_token_id"
                printf %s "$first_keyslot"
                return 0
            else
                log_warn -t luks 'Passphrase NOT found in keyslot %s from token %s' "$first_keyslot" "$one_token_id"
            fi
        fi
    fi
    local keyslots=( $(lc_misc printf %s "${luksmd[$cryptdev]}" | lc_misc jq -j '.keyslots | keys | join(" ")') )
    local i
    for i in "${keyslots[@]}"; do
        if [ "$i" = "$first_keyslot" ]; then
            log_debug -t luks 'Skipping keyslot %s' "$i"
        elif lc_luks -Q cryptsetup luksOpen --test-passphrase -d "$LUKS_KEY" --key-slot "$i" "$cryptdev" </dev/null >/dev/null; then
            log_info -t luks 'Passphrase found in keyslot %s' "$i"
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
    for k in counterhandle pcrlist; do
        args+=( --rawfile "${k//./_}" "$workdir/$k" )
        json+=", \"$k\": \$${k//./_}"
    done
    for k in countervalue pcrvalues sealed.priv sealed.pub; do
        base64 -w 0 <$workdir/$k >$workdir/$k.b64
        args+=( --rawfile "${k//./_}" "$workdir/$k.b64" )
        json+=", \"$k\": \$${k//./_}"
    done
    local keyslot=$(get_emboot_key_slot "$cryptdev")
    [ -n "$keyslot" ] || {
        log_fatal -t luks 'No key slots on %s matching %s' "$cryptdev" "$LUKS_KEY"
        return 1
    }
    lc_misc jq --null-input "${args[@]}" --arg krel "$krel" --arg keyslot "$keyslot" --arg updated "$(date +%s)" '{ "type": "emboot", "keyslots": [ $keyslot ], "krel": $krel, "updated": $updated'"$json"' }' >$workdir/token.json
    local current_token_ids=( $(list_luks_token_ids "$cryptdev" "$krel") )
    for k in "${current_token_ids[@]}"; do
        lc_luks cryptsetup token remove "$cryptdev" --token-id "$k"
    done
    lc_luks cryptsetup token import "$cryptdev" --json-file "$workdir"/token.json

    evict_luks_metadata "$cryptdev"
}

# Removes LUKS tokens for a given kernel release.
remove_luks_token() {
    local cryptdev=$1
    local krel=$2
    local krel_token_ids=( $(list_luks_token_ids "$cryptdev" "$krel") )
    for k in "${krel_token_ids[@]}"; do
        lc_luks cryptsetup token remove "$cryptdev" --token-id "$k"
    done
    evict_luks_metadata "$cryptdev"
}

stub_does_extra_pcr_4_measurement() {
    local loader=$1
    local stubver=$(strings "$loader" | grep LoaderInfo | awk '{print $4;}')
    if [ -n "$stubver" ]; then
        if (( ${stubver%%.*} < 252 )); then
            log_debug -t loader 'Found pre-LoadImage stub (version %s)' "$stubver"
            return 1
        elif (( ${stubver%%.*} < 259 )); then
            log_debug -t loader 'Found LoadImage-era stub (version %s)' "$stubver"
            return 0
        else
            log_debug -t loader 'Found post-LoadImage stub (version %s)' "$stubver"
            return 1
        fi
    fi

    log_warn -t loader %s 'Stub version not found; falling back to checking event log'
    bsa_count=$(lc_tpm -Q tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements | awk '
    $1 == "-" && $2 == "EventNum:" { inpcr4=0; inbsa=0; next}
    $1 == "PCRIndex:" && $2 == "4" { inpcr4=1; next }
    inpcr4 && $1 == "EventType:" && $2 == "EV_EFI_BOOT_SERVICES_APPLICATION" { inbsa=1; print "pcr4bsa"; next }' | wc -l)
    if (( bsa_count == 1 )); then
        log_debug -t loader 'One BSA event: assuming old stub'
        return 1
    elif (( bsa_count == 2 )); then
        log_debug -t loader 'Two BSA events: assuming new stub; will measure kernel section'
        return 0
    else
        log_debug -t loader 'BSA event count is %d > 2: unknown behavior, so defaulting to extra kernel section measurement' "$bsa_count"
        return 0
    fi
}

# Given a working directory (or $PWD if empty) containing a monotonic counter
# handle `counterhandle` with value `countervalue` and a comma-separated list
# of PCRs `pcrlist`; a path to a loader; and a kernel release string (of the
# form returned by uname -r), seals the LUKS passphrase to the loader by
# predicting future PCR values based on the UEFI boot log for the current boot.
# Will bomb out if the system has not been booted from either the primary or
# old emboot boot entry.
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
        log_fatal -t efi 'Cannot seal under non-emboot boot chain (BootCurrent=%s)' "$efi_boot_current"
        return 1
    fi

    local measurements=( 4 bsa "$loader" )
    if stub_does_extra_pcr_4_measurement "$loader"; then
        local kernelf=$workdir/kernel.img
        objcopy --dump-section .linux="$kernelf" "$loader"
        measurements+=( 4 bsa "$kernelf" )
    fi

    pcr_oracle_debug=
    if (( EMBOOT_VERBOSE >= $LL_DEBUG )); then pcr_oracle_debug=-ddd; fi

    predict_future_pcrs "$(cat "$workdir"/pcrlist)" "$workdir"/pcrvalues $pcr_oracle_debug --stop-event bsa-path="${current_loader//\\//}" "${measurements[@]}"

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
            log 'Existing EFI boot loader entry %s for %s' "${entry[0]}" "$lbn"
        else
            tag=$(printf %s "$lbn" | grep '_[^.]' | sed -e 's/^[^_]*_\([^.]\+\).*/\1/')
            log "Creating EFI boot loader entry for %s%s" "$lbn" "${tag:+ with tag $tag}"
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
            log 'Missing emboot EFI boot entries: not updating boot order'
            exit 1
        fi
        if [ "${efi_boot_order[0]}" == "$primary_bn" -a "${efi_boot_order[1]}" == "$old_bn" ]; then
            log 'No need to update EFI boot order'
            exit 0
        fi
        new_boot_order=( $primary_bn $old_bn )
        for bn in ${efi_boot_order[@]}; do
            if [ "$bn" != "$primary_bn" -a "$bn" != "$old_bn" ]; then
                new_boot_order+=($bn)
            fi
        done
        IFS=','
        log 'Updating EFI boot order to %s' "${new_boot_order[*]}"
        lc_efi -Q efibootmgr -o "${new_boot_order[*]}"
        OFS=$oldIFS

        evict_efi_vars
    else
        log 'Updating EFI boot order disabled by config'
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
            :) log_fatal -t core '%s requires an argument' "$OPTARG"; exit 1;;
            ?) log_fatal -t core 'unknown argument'; exit 1;;
        esac
    done
    shift $((OPTIND-1))

    cleanup() {
        rc=$?
        [ -n "$EMBOOT_NOCLEAN" ] || [ -z "$tmpdir" ] || rm -rf "$tmpdir"
        exit $rc
    }

    trap cleanup EXIT

    tmpdir=$(setup_tmp_dir)

    rootdev=( $(get_device_info /) )
    cryptdev=( $(get_crypttab_entry "${rootdev[1]}") )

    cryptopts=${cryptdev[3]}
    if [[ $cryptopts != *luks* ]]; then
        log_fatal 'crypttab entry missing luks option: %s' "$cryptopts"
        exit 1
    fi
    if [[ $cryptopts != *keyscript=*emboot_unseal.sh* ]]; then
        log_fatal 'keyscript option in crypttab entry missing or invalid: %s' "$cryptopts"
        exit 1
    fi

    printf 'root=UUID=%s cryptdevice=%s:%s %s\n' "${rootdev[0]}" "${cryptdev[1]}" "${cryptdev[0]}" "$KERNEL_PARAMS" >$tmpdir/kcli.txt

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
                    log_warn -t loader 'Initrd image %s for %s unavailable to create loader %s' "$initrd" "$loader_krel" "$loader"
                    lc_misc rm -f "$loader"
                    if [ -z "$suffix" ]; then
                        log_error -t loader,efi 'ERROR: primary emboot EFI entry is unbootable!'
                    fi
                else
                    printf %s "$loader_krel" >$tmpdir/krel.txt
                    log 'Creating EFI loader %s for %s' "$loader" "$loader_krel"
                    create_loader "$kernel" "$initrd" "$tmpdir"/kcli.txt "$tmpdir"/krel.txt "$tmpdir"/linux.efi
                    lc_misc cp -f "$tmpdir"/linux.efi "$loader"
                    log_info -t loader,luks 'Removing any existing tokens for %s' "$loader_krel"
                    remove_luks_token "${cryptdev[1]}" "$loader_krel"
                fi
            else
                log_info -t loader 'Skipping creation of EFI loader %s for %s' "$loader" "$loader_krel"
            fi
        else
            log_warn -t loader 'No kernel available to create loader %s' "$loader"
            lc_misc rm -f "$loader"
            if [ -z "$suffix" ]; then
                log_error -t loader,efi 'ERROR: primary emboot EFI entry is unbootable!'
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
            :) log_fatal -t core '%s requires an argument' "$OPTARG"; exit 1;;
            ?) log_fatal -t core 'unknown argument'; exit 1;;
        esac
    done
    shift $((OPTIND-1))

    cleanup() {
        rc=$?
        [ -n "$EMBOOT_NOCLEAN" ] || [ -z "$tmpdir" ] || rm -rf "$tmpdir"
        exit $rc
    }

    trap cleanup EXIT

    tmpdir=$(setup_tmp_dir)

    # Setup that doesn't change with multiple tokens
    printf %s "$COUNTER_HANDLE" >$tmpdir/counterhandle
    printf %s "$SEAL_PCRS" >$tmpdir/pcrlist
    read_counter "$COUNTER_HANDLE" "$tmpdir"/countervalue

    # Debug code for manipulating counter
    if ((EMBOOT_ADD_TO_COUNTER != 0)); then
        ((curctr=0x$(xxd -p -c9999 <$tmpdir/countervalue) ))
        ((sealctr=curctr+$EMBOOT_ADD_TO_COUNTER))
        printf %016x $((sealctr)) | xxd -r -p -c9999 >$tmpdir/countervalue
        printf 'Using monotonic counter value %d (=%d+%d)\n' "$((sealctr))" "$((curctr))" "$EMBOOT_ADD_TO_COUNTER"
    fi

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
                    log -t loader,luks 'Creating token for EFI loader %s for %s' "$loader" "$loader_krel"
                    seal_and_create_token "$tmpdir" "${cryptdev[1]}" "$loader" "$loader_krel"
                else
                    log_info -t loader,luks 'Preserving existing token for EFI loader %s for %s' "$loader" "$loader_krel"
                fi
            else
                log_warn -t loader 'Unable to extract kernel release from EFI loader %s' "$loader"
                if [ -z "$suffix" ]; then
                    log_error -t loader,luks,efi 'ERROR: primary emboot EFI entry may be unbootable or may require manual passphrase entry!'
                fi
            fi
        else
            log_warn -t loader 'EFI loader %s does not exist' "$loader"
            if [ -z "$suffix" ]; then
                log_error -t loader,efi 'ERROR: primary emboot EFI entry is unbootable!'
            fi
        fi
    done

    exit 0
)}
