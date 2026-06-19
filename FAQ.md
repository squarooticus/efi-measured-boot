# Frequently-asked Questions

## What motivated this work?

I have machines left unattended in lots of places: most mundanely, I often travel with my laptop and leave it in my hotel room. While my data is all encrypted-at-rest, getting access to the data when the machine is first powered on necessarily involves running some code that is neither encrypted nor authenticated: namely, the bootloader and enough of the operating system kernel to decrypt and mount volumes.

Furthermore, this process requires me to type in a passphrase every time I boot the machine, which exposes the passphrase to anyone observing surreptitiously, and is in general an annoyance.

## What is the threat model addressed by measured boot?

My adversary is someone who intends to tamper with my machine without my knowledge, with the purposes of either making off with some information or instrumenting the machine such that information encrypted-at-rest is revealed to the attacker out-of-band.

There's not a lot of value to me in tamper prevention: once someone's screwed with my machine, I am unlikely to trust it again regardless. My main goal is confidentiality-at-rest and tamper detection. I thus settled on measured boot, which measures the sequence of executable code launched during the boot process in a way that is highly resistant to forgery: at the end of this process, this measurement can be used to verify that the machine has not been tampered with, as well as to unlock disk encryption keys that can be used to mount volumes without requiring the user enter a passphrase.

There are a number of technologies that can reduce (but of course not eliminate) the attack surface of a machine. Other measures are required for runtime protection against zero-day remote exploits, physical attacks that employ USB DMA, tire irons, etc., as well as some advanced kinds of physical tampering.

## How do you boot securely in situations that require entering a passphrase?

If for whatever reason (e.g., BIOS upgrade) you know in advance that you're going to need to enter the passphrase on startup, make sure to follow a procedure like the one below to minimize the risk of compromise:

1. First, avoid making any such change when you do not have a secure location available to complete this procedure! Once you've made a change that breaks measured boot, you must wait until getting to a secure location to fix it, or even to boot.

    Ideally, also physically disable networking from here until procedure completion.

1. Second, confirm measured boot success before making the change: this means rebooting once as-normal to confirm machine integrity.

1. Make the breaking change.

1. Now, reboot into emboot. Measured boot will fail and you will be prompted for your passphrase. This is where being in a secure physical location really matters, because—absent a Yubikey or other device that enters your passphrase without someone being able to observe your typing—you may expose your passphrase to a passive adversary.

1. `sudo update-emboot -s`, and confirm via another reboot that measured boot is back in business.

## What is the TPM policy, and why is it structured that way?

The TPM policy is to seal the passphrase to a selected set of PCRs, and to a monotonic counter less than or equal to a given value:

- The default set of PCRs includes 0, 2, and 4. By spec, these PCRs are used to measure:

    - **PCR 0: Core system firmware.** This covers the BIOS/UEFI firmware executable code itself.

    - **PCR 2: Extended or option ROM code.** This covers externally-supplied executable code that gets loaded and executed by the firmware, mainly option ROMs from expansion cards.

    - **PCR 4: Loader/EFI application.** In this solution, this is the UKI: primarily the kernel, the initrd, and the kernel command line.

    Any time any of those measured elements changes, the corresponding PCR will change, which will prevent the TPM from unsealing the passphrase at boot time.

- The monotonic counter is used to invalidate older UKIs so downgrade attacks are not possible. When a vulnerable boot chain is discovered, the counter can be permanently incremented and the passphrase sealed anew to updated boot chain(s) without that vulnerability. In practice, the counter is incremented whenever a kernel is removed so any UKIs built with that now-deprecated kernel will fail to unseal the passphrase; subsequently, the passphrase is re-sealed to every remaining UKI.

    The key to this capability is that a counter can never be decremented or reset to zero without resetting the TPM, essentially invalidating all credentials issued by, and all secrets ever sealed by, the TPM.

## What about injection attacks?

The one bit of unmeasured boot chain input under the ready control of an adversary is the JSON metadata in the LUKS header. One major concern for a system like this is that it not enable injection attacks in which `emboot_unseal.sh` could successfully unseal the passphrase but then exfiltrate that passphrase, either off-machine or to some other unprivileged location accessible by someone with physical access to the machine. It is therefore critical, for instance, that all output from JSON queries is double-quoted in command lines so they are regarded as strings rather than as separate words in command line expansion.

A few additional belt-and-suspenders checks were added to improve confidence in the correctness of adversary-controlled data:

- Use `jq` to reject non-strings where strings are expected.
- Validate the string format of both counter handles and PCR lists.

Notwithstanding bugs in dash, this avenue of attack should be closed, but the risk here warrants increased scrutiny of any future changes to anything in the unseal chain.
