#!/usr/bin/env python3
import argparse
import collections
import json
import os
import pwd
import signal
import sys
import time

KB = 1024

_terminate = False


def _finish_on_term(signum, frame):
    global _terminate
    _terminate = True


def meminfo():
    out = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, v = line.partition(":")
            out[k] = int(v.strip().split()[0])  # kB
    return out


def classify(cmdline, exe):
    c = cmdline
    if "/usr/local/bin/opencode" in c or exe == "opencode":
        return "opencode"
    if "chromium" in c or "chrome_crashpad" in c:
        return "chromium"
    for lsp in ("language-server", "language_server", "gopls", "rust-analyzer",
                "pyright", "tsserver", "typescript", "clangd", "jdtls"):
        if lsp in c:
            return "lsp"
    if "/tailscaled" in c:
        return "tailscale"
    if exe in ("node", "bun", "deno"):
        return "node"
    if exe in ("Xvfb", "x11vnc"):
        return "display"
    return "other"


def sample():
    by_user = collections.Counter()
    by_kind = collections.Counter()
    total = 0
    seen = 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/smaps_rollup") as f:
                pss = 0
                for line in f:
                    if line.startswith("Pss:"):
                        pss = int(line.split()[1])
                        break
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmdline = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            st = os.stat(f"/proc/{pid}")
            exe = os.path.basename((cmdline.split(" ") or [""])[0])
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        if pss == 0:
            continue
        try:
            user = pwd.getpwuid(st.st_uid).pw_name
        except KeyError:
            user = str(st.st_uid)
        by_user[user] += pss
        by_kind[classify(cmdline, exe)] += pss
        total += pss
        seen += 1
    return by_user, by_kind, total, seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--label", default="unlabelled")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    mi0 = meminfo()
    memtotal = mi0["MemTotal"]
    nproc = os.cpu_count() or 1

    peak_user = collections.Counter()
    peak_kind = collections.Counter()
    peak_total = 0
    min_avail = mi0["MemAvailable"]
    max_load = 0.0
    peak_swap_used = 0
    samples = 0

    deadline = time.time() + args.seconds
    signal.signal(signal.SIGTERM, _finish_on_term)
    try:
        while time.time() < deadline and not _terminate:
            by_user, by_kind, total, _ = sample()
            mi = meminfo()
            load1 = os.getloadavg()[0]

            for k, v in by_user.items():
                peak_user[k] = max(peak_user[k], v)
            for k, v in by_kind.items():
                peak_kind[k] = max(peak_kind[k], v)
            peak_total = max(peak_total, total)
            min_avail = min(min_avail, mi["MemAvailable"])
            max_load = max(max_load, load1)
            peak_swap_used = max(peak_swap_used, mi["SwapTotal"] - mi["SwapFree"])
            samples += 1
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass

    used_by_peak = memtotal - min_avail

    def render():
        if args.json:
            return json.dumps({
                "label": args.label, "samples": samples,
                "memtotal_mb": memtotal // KB,
                "peak_pss_mb": peak_total // KB,
                "min_memavailable_mb": min_avail // KB,
                "peak_swap_used_mb": peak_swap_used // KB,
                "max_load1": max_load, "nproc": nproc,
                "by_kind_mb": {k: v // KB for k, v in peak_kind.most_common()},
                "by_user_mb": {k: v // KB for k, v in peak_user.most_common()},
            }, indent=1)

        lines = [
            f"\n=== {args.label} ===",
            f"{samples} samples over ~{args.seconds}s, {nproc} vCPU, MemTotal {memtotal // KB} MB\n",
            "peak PSS by kind (MB)",
        ]
        for k, v in peak_kind.most_common():
            lines.append(f"  {k:12} {v // KB:6}")
        lines.append("\npeak PSS by user (MB)  <- one user per client, so this is the per-client bill")
        for k, v in peak_user.most_common():
            lines.append(f"  {k:12} {v // KB:6}")
        lines += [
            f"\npeak PSS total        {peak_total // KB:6} MB",
            f"min MemAvailable      {min_avail // KB:6} MB   (independent cross-check)",
            f"used at that moment   {used_by_peak // KB:6} MB",
            f"peak swap in use      {peak_swap_used // KB:6} MB   (zram; >0 means real pressure)",
            f"max 1-min load        {max_load:6.2f}    on {nproc} vCPU"
            + ("   <-- CPU BOUND" if max_load > nproc else ""),
            "",
        ]
        return "\n".join(lines)

    out = render()
    print(out)


if __name__ == "__main__":
    sys.exit(main())
