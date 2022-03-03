#! /bin/bash

provision_counter() {
    tpm2_nvundefine $COUNTER_HANDLE -Q || true
    tpm2_nvdefine $COUNTER_HANDLE -C o -s 8 -g sha256 -a 'ownerread|ownerwrite|policywrite|nt=counter'
    tpm2_nvincrement -C o $COUNTER_HANDLE
}

create_provision_context() {
    tpm2_createprimary -Q -C o -g sha256 -G ecc256:null:aes128cfb -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|restricted|decrypt' -c provision.ctx
}

seal_data() {
    tpm2_startauthsession -S session.ctx
    tpm2_policypcr -S session.ctx -l sha256:$SEAL_PCRS -f future_pcrs
    tpm2_policynv -S session.ctx -C o -i counter -L policy $COUNTER_HANDLE ule
    tpm2_create -C provision.ctx -g sha256 -a 'fixedtpm|fixedparent|adminwithpolicy|noda' -i - -L policy -r sealed.priv -u sealed.pub
    tpm2_flushcontext session.ctx
    rm -f session.ctx
}

predict_future_pcrs() {
    path_efi_app=$1
    os_caps=$(echo -n "$OS_SHORT_NAME" | tr a-z A-Z)
    tpm_futurepcr -L $SEAL_PCRS -H sha256 ${path_efi_app:+--substitute-bsa-unix-path "/boot/efi/EFI/$os_caps/$os_caps.EFI=$path_efi_app" --substitute-bsa-unix-path "/boot/efi/EFI/$os_caps/${os_caps}_OLD.EFI=$path_efi_app" --substitute-bsa-unix-path "/boot/efi/EFI/$os_caps/LINUX.EFI=$path_efi_app"} -o future_pcrs -v
}

create_efi_app() {
    kernel=$1
    initrd=$2
    output=$3
    objcopy --add-section .osrel="/usr/lib/os-release" --change-section-vma .osrel=0x20000 \
        --add-section .cmdline="./kernel-command-line.txt" --change-section-vma .cmdline=0x30000 \
        --add-section .linux="$kernel" --change-section-vma .linux=0x2000000 \
        --add-section .initrd="$initrd" --change-section-vma .initrd=0x3000000 \
        /usr/lib/systemd/boot/efi/linuxx64.efi.stub "$output"
}

emboot_install() {
    mkdir -m 0700 -p /tmp/emboot-setup
    cd /tmp/emboot-setup

    rootdev=( $("$APPDIR"/get_device_info /) )
    cryptdev=( $("$APPDIR"/get_crypttab_entry ${rootdev[1]}) )

    if [[ ${cryptdev[3]} != *luks* ]]; then
        echo 'crypttab entry missing luks option' 1>&2
        echo "${cryptdev[3]}" 1>&2
        exit 1
    fi

    if [[ ${cryptdev[3]} != *keyscript=*emboot_unseal* ]]; then
        echo 'keyscript option in crypttab entry missing or invalid' 1>&2
        echo "${cryptdev[3]}" 1>&2
        exit 1
    fi

    echo "root=UUID=${rootdev[0]} cryptdevice=${cryptdev[1]}:${cryptdev[0]} $KERNEL_PARAMS" >./kernel-command-line.txt

    main_loader="$EFI_MOUNT"/"$(echo "EFI/$OS_SHORT_NAME/$OS_SHORT_NAME.EFI" | tr a-z A-Z)"
    old_loader="$EFI_MOUNT"/"$(echo "EFI/$OS_SHORT_NAME/${OS_SHORT_NAME}_OLD.EFI" | tr a-z A-Z)"
    create_efi_app /vmlinuz /initrd.img "$main_loader"
    create_efi_app /vmlinuz.old /initrd.img.old "$old_loader"

    sudo rm -rf /tmp/emboot-setup

    return 0
}

seal_to_efi_app() {
    kernel=$1
    loader=$2
    rm -f sealed.pub sealed.priv
    predict_future_pcrs "$loader"
    seal_data <$LUKS_KEY
    vmlinuz_target=$(basename $(readlink "$kernel"))
    efi_emboot_dir=$EFI_MOUNT/EFI/$OS_SHORT_NAME/emboot/${vmlinuz_target#vmlinuz-}
    mkdir -p "$efi_emboot_dir"
    cp -f counter sealed.pub sealed.priv "$efi_emboot_dir"
}

emboot_seal_key() {
    mkdir -m 0700 -p /tmp/emboot-setup
    cd /tmp/emboot-setup

    read_counter >counter
    create_provision_context
    main_loader="$EFI_MOUNT"/"$(echo "EFI/$OS_SHORT_NAME/$OS_SHORT_NAME.EFI" | tr a-z A-Z)"
    old_loader="$EFI_MOUNT"/"$(echo "EFI/$OS_SHORT_NAME/${OS_SHORT_NAME}_OLD.EFI" | tr a-z A-Z)"
    seal_to_efi_app /vmlinuz "$main_loader"
    seal_to_efi_app /vmlinuz.old "$old_loader"

    sudo rm -rf /tmp/emboot-setup

    return 0
}

buildre() {
    local IFS='|'
    echo "${*//\//\\\/}"
}

get_crypttab_entry() {
    devnode=$1

    parentdevices=( $(lsblk -s -t $devnode -o UUID -n -r | grep '.') )
    parentdevicenodes=( $(lsblk -p -s -t $devnode -o NAME -n -r | grep '.') )
    OLDIFS=$IFS
    local IFS=$'\n'
    crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep -E "UUID=($(buildre ${parentdevices[@]}))" || true) )
    if (( ${#crypttabentries[@]} == 0 )); then
        echo 'crypttab entry not found via UUID; trying node' 1>&2
        crypttabentries=( $(sed -e 's/#.*//' /etc/crypttab | grep -E "$(buildre ${parentdevicenodes[@]})" || true) )
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
    cryptdev=( ${crypttabentries[0]} )

    IFS=' '
    echo "${cryptdev[*]}"
}

get_device_info() {
    trace_path=${1:-/}

    mount_point=$(stat -c '%m' $trace_path)
    dev=( $(lsblk -n -o UUID,PATH,MOUNTPOINT -r | awk '$3 == "'"$mount_point"'" { print $1 " " $2; }') )
    if (( ${#dev[@]} == 0 )); then
        echo "no block device found with mount point $mount_point" 1>&2
        exit 1
    fi
    devuuid=${dev[0]}
    devnode=${dev[1]}

    echo "$devuuid $devnode"
}
