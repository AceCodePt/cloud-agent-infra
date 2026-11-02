# Boot volume capacity (OCI)

The OCI path asks Terraform for a **100 GB** boot volume
(`terraform/oci/compute.tf`, `boot_volume_size_in_gbs = 100`) plus a **50 GB**
block volume for `/mnt/data`. On this provider those two numbers can diverge
from what `df` shows, and the difference is easy to mistake for a full disk.

## What the image actually gives you

The stock Oracle Linux 9 platform image ships a **fixed 46.6 GiB partition
table**. When the boot volume is larger, the remainder is unallocated — present
on the disk, invisible to LVM and to `df`:

```
/dev/sda  100 GiB
├─ sda1     0.1G  EFI
├─ sda2     2.0G  /boot
├─ sda3    44.5G  LVM PV            <-- image default
│  ├─ ocivolume-root  29.5G  /
│  └─ ocivolume-oled  15.0G  /var/oled
└─ (free)  53.4G                     <-- never added to the partition table
```

So a 100 GB boot volume shows up as a **30 GB root filesystem**. `pvs` reports
`PSize 44.50g` and `parted /dev/sda print free` shows the 53.4 GiB of free
space; `df` shows neither.

The image also preallocates a **5 GB `/.swapfile`**. `startup.rhel.sh` adds zram
on top (`zram-size = min(ram / 2, 4096)`), so the effective swap budget is
5 GB file + 4 GB zram before you touch anything.

## Why this box came up at 29.5G

The grow block used to extend only the **root LV** into free **VG** extents:

```sh
FREE_EXTENTS="$(vgs --noheadings -o vg_free_count ...)"
[ "$FREE_EXTENTS" -gt 0 ] && lvextend -l +100%FREE "$ROOT_LV"
```

It never ran `growpart` or `pvresize`. With the image's partition table at
44.5G, `vg_free_count` is `0`, so the block was **skipped silently** — no log
line, no failure — and root stayed at 29.5G on a 100G volume.

The template now grows the partition and PV before the LV:

```sh
ROOT_PV=...                              # PV backing the root LV
growpart "/dev/$ROOT_DISK" "$ROOT_PARTN" # no-op when already full
pvresize "$ROOT_PV"
# then lvextend + xfs_growfs, as before
```

Both steps are idempotent, and `growpart` returning non-zero on an
already-full partition is treated as the steady state, not an error. New boxes
therefore fill the volume on first boot.

A box built with the older template (like the one this doc was written for)
still needs the manual step below. `./run verify` now fails such a box with an
"unallocated space" message instead of letting it run quietly at 29.5G.

## Reclaiming it by hand

Online, no reboot. `growpart` rewrites the GPT entry without moving the start
sector; `pvresize`, `lvextend`, and `xfs_growfs` are all online operations.

```sh
sudo growpart /dev/sda 3      # 44.5G -> ~97.9G
sudo pvresize /dev/sda3       # VG ocivolume -> ~97.9G
sudo lvextend -l +100%FREE /dev/ocivolume/root
sudo xfs_growfs /             # root -> ~82.9G
```

`ocivolume-oled` stays at 15G; nothing else needs to move.

Verify after each step:

```sh
lsblk -o NAME,SIZE,TYPE /dev/sda
sudo pvs --units g && sudo lvs --units g
df -h /
```

Expected end state: `sda3` 97.9G, VG 97.9G, root LV 82.9G, `/` 83G.

## After a future resize

`source_details` is in `ignore_changes`, so Terraform is bootstrap-only for the
boot volume. Expanding it later (console or API) will **not** be picked up by
`apply` and the guest will still see the old size. Re-run the four commands
above on the box; `./run verify` reports the box as failing until you do.

## Related

- `docs/operating.md` → Persistence model (the 50 GB data disk at `/mnt/data`)
- `docs/decisions/infrastructure.md` → "Separate persistent data disk at `/mnt/data`"
- `scripts/templates/startup.rhel.sh` — partition/PV/LV grow block, zram config
- `scripts/verify.sh` — asserts the root partition fills the boot volume
