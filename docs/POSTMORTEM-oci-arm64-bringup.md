# Postmortem: Why the OCI Arch ARM64 bring-up cost so much time

Date: 2026-08-09
Scope: Bringing up a cloud-agent Arch Linux ARM64 VM on OCI free-tier A1.Flex from a locally built golden image.

---

## 1. Executive summary

A task that should have taken a handful of iterations took many hours and a large
number of full cloud deploy cycles. The technical problems were ultimately mundane
and each had a clear, small fix. The dominant cost was **process**, not engineering:
repeated 30-minute blind cloud cycles, diagnosing one layer at a time, with no local
feedback loop and no console-visible error output until very late.

There were **four independent root causes** stacked on top of each other. Each was
found, then the next one appeared. In order:

1. OCI custom images imported with the wrong firmware (BIOS instead of UEFI_64) →
   VM "runs" but never boots.
2. A 1 MiB filesystem-geometry bug (ext4 superblock larger than its partition) →
   kernel refuses to mount root → emergency mode.
3. A build-image script bug that made `mkfs.ext4` size the filesystem from the
   wrong device (this was the same bug as #2, discovered late).
4. `systemd-firstboot` blocking first boot on an interactive timezone prompt →
   cloud-init/user_data never runs → box never joins the tailnet.

The 1 MiB geometry bug (#2/#3) was the one that burned most of the time, and it
was invisible until the real mount error was surfaced.

---

## 2. Timeline (compressed, with the real costs)

| Stage | What happened | Time |
|---|---|---|
| Packer → QEMU/chroot build rewrite | Fine, worked first time. | 1x |
| Image build + upload + import | Discovered OCI imports with **BIOS firmware**; A1 is UEFI-only. VM never booted. | ~2 cycles |
| Re-import as UEFI_64 | Firmware boots, GRUB loads kernel, but **root never mounts** → emergency mode. | — |
| Guessing at the mount failure | Tried removing the fsck hook, adding virtio_scsi, changing console flags — all plausible, all wrong. | ~3 cycles, ~90 min |
| Local QEMU reproduction | Set up late; confirmed the same failure in minutes. | — |
| Real error surfaced | `systemd.journald.forward_to_console=1` + `loglevel=7` finally printed the actual kernel error. | 1 cycle |
| Fix geometry bug | Root mounts. Boot is healthy on OCI. | verified |
| Firstboot prompt | Fresh OCI boot hangs at `systemd-firstboot` timezone prompt → cloud-init never runs. | caught live |
| Stop | User stopped here. | — |

A "cycle" here = build (~10 min) → qemu-img convert (~2 min) → upload 3.1 GB
(~5 min) → OCI import (~5 min) → `tf apply -replace` (~3 min) → boot + wait
(~3-5 min). Roughly **25-30 min per full cycle**, and the loop was executed many times.

---

## 3. The four root causes in detail

### 3.1 Firmware: BIOS vs UEFI_64

**Symptom:** instance shows RUNNING but the boot never starts; serial console empty.

**Cause:** `oci compute image import from-object --launch-mode PARAVIRTUALIZED`
hardcodes `firmware=BIOS` on the resulting image. Oracle's A1 (Arm) shapes are
UEFI-only — the firmware never hands off to GRUB.

**Fix:** import via the raw API with `launchMode: CUSTOM` + `launchOptions.firmware:
UEFI_64`, then add `VM.Standard.A1.Flex` to `image-shape-compatibility-entry`
(imported images register as x86 with no A1 shapes). `import-image.sh` was rewritten
to do this.

**Why it cost time:** OCI's CLI happy path silently produces a dead image. There is
no warning. Only a serial/console observation reveals "nothing ever booted".

### 3.2 The 1 MiB geometry bug (the big one)

**Symptom:** boot gets all the way to the root mount, udev finds the disk by label,
filesystem is clean — then:

```
Mounting /sysroot...
[FAILED] Failed to mount /sysroot.
```

**Real error (hidden until debug output was enabled):**

```
EXT4-fs (sda2): bad geometry: block count 1441536 exceeds size of device (1441280 blocks)
```

**Cause:** the root loop device used to create the filesystem was attached with an
offset but **no `--sizelimit`**:

```bash
ROOT="$(losetup -f --show -o $((ESP_START + ESP_SIZE)) "$IMG")"
```

`parted` reserves the **last ~2 MiB of the disk for the backup GPT header**, so the
partition `513MiB → 100%` is 1 MiB smaller than the raw image remainder. `mkfs.ext4`
sized the filesystem to the oversized loop device (1441536 blocks) while the
partition only holds 1441280 blocks. The kernel refuses to mount a filesystem that
claims to be bigger than its device.

**Fix:**

```bash
ROOT_SIZE_SECTORS="$(parted -s "$IMG" unit s print | awk '$1==2 {gsub("s","",$4); print $4}')"
ROOT_SIZE_BYTES=$((ROOT_SIZE_SECTORS * 512))
ROOT="$(losetup -f --show -o $((ESP_START + ESP_SIZE)) --sizelimit "$ROOT_SIZE_BYTES" "$IMG")"
```

Read the partition size from the GPT itself so it can never drift out of sync.

**Why it cost so much time:**
- **The error was never visible.** The console only prints
  `See 'systemctl status sysroot.mount' for details` — the actual message lives in
  the journal, which is not on the serial console by default. We debugged blind for
  several cycles.
- Every plausible suspect *checked out*: ext4 was built into the kernel
  (`modules.builtin`), the filesystem was clean (`e2fsck` passed), the label
  resolved, udev found the device. All true — and all irrelevant, because the
  problem was pure geometry (superblock vs device size).
- The debug flags (`systemd.journald.forward_to_console=1`, `loglevel=7`) that would
  have revealed it were added late, and ironically then caused their own problems
  (see 3.4).

### 3.3 Red herrings chased before the real fix

Because we couldn't see the mount error, plausible-but-wrong fixes were applied:

- **Removed the mkinitcpio `fsck` hook** — fsck wasn't the problem, but the initramfs
  genuinely lacked `fsck.ext4`, so this *looked* plausible and was kept.
- **Added `virtio_scsi sd_mod` to MODULES=** — the drivers were already built into
  the kernel (`modules.builtin`), making these no-ops. Harmless, kept.
- **Rechecked initramfs contents, udev rules, blkid, fstab-generator** — all present
  and correct.
- **Suspected the by-label symlink, the ESP label, mount options** — none were wrong.

Each of these was a reasonable hypothesis; none was the cause. Without the journal
line, we were guessing from a position of high uncertainty.

### 3.4 systemd-firstboot blocking first boot

**Symptom:** after the geometry fix, the box boots fully (Switch Root, hostname
`cloud-agent`) but never joins the tailnet. Auth key valid, network egress fine.

**Cause (caught live on the serial console):**

```
Please enter the new timezone name or number ("list" to list options, empty to skip):
```

`systemd-firstboot` runs on **first boot** when `/etc/machine-id` is missing (the
golden image strips it). It prompts interactively for timezone/keymap/locale and
**blocks the boot** until answered. Since cloud-init's `user_data` (which runs
tailscale) is gated behind the normal boot reaching `multi-user.target`, and the
serial console is unattended, the box sat at the prompt forever.

**Why QEMU didn't catch it:** the local QEMU boots were **re-boots of an
already-booted image**, so `/etc/machine-id` was already set and firstboot never
ran. Only a truly fresh boot (what OCI does) triggers it. This is a classic
golden-image first-boot pitfall.

**Fix (in the image):**
- Bake `/etc/localtime` (symlink to UTC) in `02-config.sh`.
- Write `KEYMAP=us` to `/etc/vconsole.conf`.
- Add `systemd.firstboot=off` to the kernel cmdline in `04-boot.sh` so it can never
  block even if something else is unset.

---

## 4. Why it cost so much time — process failures

Ranked by total cost:

1. **Debugging without the error output.**
   The single most expensive mistake. The mount failure's actual message was one
   journal line away, but the console doesn't show the journal. Adding
   `systemd.journald.forward_to_console=1` (and, in hindsight, a debug-shell or
   `rd.debug`) at the start would have ended this in one cycle instead of ~4.

2. **No local iteration loop until late.**
   A local QEMU reproduction (aarch64 TCG + AAVMF firmware + virtio-scsi disk)
   reproduced the identical mount failure in ~4 minutes, at zero cloud cost. It was
   only set up after several expensive cloud cycles. It should have been the first
   tool, not the last.

3. **Batch-fix mentality driven by the slow cycle.**
   Because each cloud cycle was ~25-30 min, there was a strong temptation to bundle
   several fixes at once to "save a cycle." This **conflated changes**, so when
   something still failed we couldn't tell which fix mattered. Slow loops incentivize
   the exact behavior that makes debugging hardest.

4. **Full 3.1 GB re-upload on every iteration.**
   Even a 6.8 MB change to the embedded GRUB binary required re-uploading the whole
   qcow2 and re-importing the image (~10 min of fixed cost). The upload was later
   parallelized (`--parallel-upload-count 8`), but the structural cost remained.

5. **Debug flags left baked into a deployed image.**
   The `loglevel=7` + `systemd.journald.forward_to_console` flags used to diagnose
   the mount bug stayed in the deployed image and **flooded the 115200-baud serial
   console**, stalling boot/cloud-init and making the OCI console-history capture
   useless (capped at 10 KB, filled with early-kernel lines). This cost an extra
   full cycle and several hours of confused serial-console work.

6. **Serial-console access friction.**
   OpenSSH 10.x rejects the `ssh-rsa` host key that OCI's serial console offers.
   Getting a working interactive console required an SSH config with
   `HostKeyAlgorithms=+ssh-rsa` etc. — solved eventually, but consumed time and
   context.

7. **Shell/tooling friction in the orchestration.**
   Backgrounded `nohup` launches were repeatedly killed by the shell-tool timeout
   before the redirect detached (an empty log file = "not actually started").
   Multiple "is it running?" checks were false positives from `pgrep` matching the
   check command itself. Low-value but real overhead.

8. **A1 host-capacity flakiness.**
   `Out of host capacity` errors on launch required a retry loop (succeeded on
   attempt 4). Free-tier A1 capacity in the region is unreliable; this added
   ~10-15 min of retry time to the final deploy.

---

## 5. What the fixes were (for the record)

| # | Fix | Where |
|---|---|---|
| 1 | Import with raw API, `launchMode=CUSTOM`, `firmware=UEFI_64`, add A1.Flex shape compat | `scripts/import-image.sh` |
| 2 | Root loop device sized to the actual GPT partition (`--sizelimit` read from parted) | `images/build-inner.sh` |
| 3 | Bake `/etc/localtime` + `KEYMAP=us` | `images/scripts/02-config.sh` |
| 4 | `systemd.firstboot=off` + `loglevel=4` on the kernel cmdline | `images/scripts/04-boot.sh` |
| 5 | Parallel multipart upload | `scripts/upload-image.sh` (`--parallel-upload-count 8`) |
| 6 | Local QEMU boot test to validate before any cloud cycle | `scripts/boot-test-local.sh` |

---

## 6. Lessons / recommendations for next time

1. **Get the error to the console before anything else.** For any boot/mount/service
   failure: enable journal-to-console (`systemd.journald.forward_to_console=1`) or a
   debug shell at the very first sign of trouble, and remove it before deploy.
2. **Build the local repro first.** Emulate the exact hardware contract (firmware,
   disk controller) locally before touching the cloud. It turns a 30-min cycle into
   a ~5-min one.
3. **Change one variable per cycle.** Resist the urge to bundle fixes. A slow cycle
   is the worst reason to batch changes.
4. **Beware fresh-boot-only bugs.** Anything gated on "first boot" (systemd-firstboot,
   machine-id, SSH host key gen, cloud-init "once" state) will not reproduce on
   re-boots of the same image. Always test a truly fresh boot — in QEMU that means
   deleting the machine-id / using a fresh copy of the image.
5. **Separate "diagnostic flags" from "ship config".** Debug flags in an image must
   be reverted before deployment; a separate build-config toggle would have avoided
   deploying the log-flood.
6. **Know the geometry contract.** Partitioning a disk image by offsets while letting
   mkfs see the full device is fragile — always size the filesystem to the
   partition, and derive the size from the partition table, never from the image.
7. **Make background jobs robust.** Use `setsid`/`disown` and verify startup by
   checking the redirect file exists and grows, not by `pgrep` (which self-matches).

---

## 7. Final state

- The **geometry bug is fixed and verified** — the image boots fully on both QEMU
  and real OCI A1 hardware (Switch Root, hostname, services starting).
- The **firstboot blocker was identified live** and the fix is written into
  `02-config.sh` / `04-boot.sh`.
- The rebuild to bake those fixes was started and stopped at the user's request.
  No further cloud cycles were run after that.

## 8. Epilogue (2026-08-10): the golden image was removed

The Arch golden-image pipeline was removed in favor of OCI's **stock Oracle Linux
9 platform image** + `startup.ol.sh` (Flatpak Chromium, GitHub-release nvim,
deferred phase B). The workload is distro-agnostic, so the bring-up bought nothing
the platform image already offers, and every future change to the box was paying a
25-30 min build→upload→import→boot cycle for the privilege. This postmortem is
kept for its process lessons (get errors to the console first, local repro before
the cloud, one variable per cycle, fresh-boot-only bugs); the pipeline itself is
gone. See [`decisions/infrastructure.md`](decisions/infrastructure.md).
