# Crash capture & auto-recovery (host: snf)

Context: snf froze **2026-06-14 18:37** with zero forensic trace — no shutdown
sequence, no OOM, empty `/var/crash` and `/sys/fs/pstore`. Root cause
undeterminable because nothing was configured to capture or auto-recover from a
panic/hang. This makes a repeat diagnosable.

snf is **BIOS/legacy** (not EFI) → `efi-pstore` is unavailable. Chosen capture =
**kdump** (full vmcore, standard Ubuntu, ~256MB reserved RAM). pstore/ramoops was
rejected (fiddly physical-address reservation on x86-BIOS, dmesg-ring only).

## What gets captured

| Failure | Caught? | By |
|---|---|---|
| Kernel panic | yes | kdump → vmcore in `/var/crash` |
| Kernel oops | yes | `panic_on_oops=1` → panic → kdump |
| Uninterruptible hang (D-state >120s) | yes | `hung_task_panic=1` → panic → kdump |
| CPU softlockup | no (by choice) | would cause spurious reboots — see conf |
| Power loss / hard PSU/RAM fault | **no** | nothing runs; needs a UPS to rule out |

After any capture the box **auto-reboots 10s later** (`kernel.panic=10`) instead
of hanging dark like it did on Jun 14.

## Install (needs root; run with `!` or sudo)

```bash
# 1. Panic/hang sysctls
sudo cp /home/user/vibemobile/vibe-daemon/deploy/60-crash-capture.conf /etc/sysctl.d/
sudo sysctl --system            # apply now (no reboot needed for these)

# 2. kdump — reserves crashkernel RAM, wires the panic→kexec path
sudo apt install kdump-tools    # accept "enable kdump" prompt; it edits GRUB
sudo update-grub                # ensure crashkernel= is on the cmdline
sudo reboot                     # crashkernel reservation only takes on boot

# 3. Verify after reboot
kdump-config show               # expect: "current state: ready to kdump"
cat /proc/cmdline | grep -o 'crashkernel=[^ ]*'   # reservation present
sysctl kernel.panic kernel.panic_on_oops kernel.hung_task_panic
```

## Test it (optional, destructive — triggers a real panic+reboot)

```bash
sudo sysctl -w kernel.sysrq=1
echo c | sudo tee /proc/sysrq-trigger   # forces a panic → kdump → reboot
# after reboot: ls -lh /var/crash/   (a dated vmcore dir = working)
```

## Reading a vmcore later

`sudo apt install crash linux-crash-dump` then
`crash /usr/lib/debug/boot/vmlinux-$(uname -r) /var/crash/<dir>/dump.*`.
Or just read `/var/crash/<dir>/dmesg.*` for the last kernel messages before death.

## RAM note

crashkernel reserves ~256MB on this 15GB box. Combined with the vibe-daemon
limits (`deploy/vibe-daemon.service`: MemoryMax=3G) and session caps, headroom
stays adequate for the docker/postgres stacks. If RAM gets tight, lower the
crashkernel reservation in GRUB (`crashkernel=192M`) before dropping the daemon caps.
