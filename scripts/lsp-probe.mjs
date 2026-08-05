#!/usr/bin/env node
import { spawn } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";

const argv = process.argv.slice(2);
const arg = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? def : argv[i + 1];
};
const has = (name) => argv.includes(`--${name}`);

const cmd = arg("cmd");
const root = arg("root");
const ext = (arg("ext", ".ts") || "").split(",");
const wantFiles = Number(arg("files", 40));
const settleMs = Number(arg("settle", 20)) * 1000;
const quietMs = Number(arg("quiet", 6)) * 1000;
const label = arg("label", cmd);
const asJson = has("json");

if (!cmd || !root) {
  console.error("usage: lsp-probe.mjs --cmd '<server> --stdio' --root <dir> [--ext .ts] [--files 40] [--settle 20] [--quiet 6] [--json]");
  process.exit(64);
}

const SKIP = new Set(["node_modules", ".git", "dist", "out", "build", ".next", "__pycache__", ".venv", "venv"]);

function collect(dir, acc = []) {
  if (acc.length >= wantFiles) return acc;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    if (acc.length >= wantFiles) break;
    if (e.name.startsWith(".") && e.name !== ".") continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP.has(e.name)) continue;
      collect(p, acc);
    } else if (ext.some((x) => e.name.endsWith(x)) && !e.name.endsWith(".d.ts")) {
      try {
        if (statSync(p).size > 2000) acc.push(p);
      } catch {}
    }
  }
  return acc;
}

const files = collect(root);
if (files.length === 0) {
  console.error(`no ${ext.join("/")} files under ${root}`);
  process.exit(65);
}

// --- process tree accounting -------------------------------------------------
function descendants(root_pid) {
  const kids = new Map();
  let pids;
  try {
    pids = readdirSync("/proc").filter((d) => /^\d+$/.test(d));
  } catch {
    return [root_pid];
  }
  for (const pid of pids) {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      const ppid = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      if (!kids.has(ppid)) kids.set(ppid, []);
      kids.get(ppid).push(Number(pid));
    } catch {}
  }
  const out = [];
  const walk = (p) => {
    out.push(p);
    for (const c of kids.get(p) || []) walk(c);
  };
  walk(root_pid);
  return out;
}

function sampleTree(pid) {
  let pss = 0, rss = 0, n = 0;
  for (const p of descendants(pid)) {
    try {
      const roll = readFileSync(`/proc/${p}/smaps_rollup`, "utf8");
      const g = (k) => {
        const m = roll.match(new RegExp(`^${k}:\\s+(\\d+) kB`, "m"));
        return m ? Number(m[1]) : 0;
      };
      const thisPss = g("Pss");
      if (thisPss === 0) continue;
      pss += thisPss;
      rss += g("Rss");
      n++;
    } catch {}
  }
  return { pss: pss / 1024, rss: rss / 1024, procs: n };
}

// --- minimal LSP client ------------------------------------------------------
const parts = cmd.split(" ").filter(Boolean);
const child = spawn(parts[0], parts.slice(1), { cwd: root, stdio: ["pipe", "pipe", "pipe"] });
child.on("error", (e) => {
  console.error(`failed to start ${parts[0]}: ${e.message}`);
  process.exit(66);
});
let stderrTail = "";
child.stderr.on("data", (d) => { stderrTail = (stderrTail + d).slice(-2000); });

let seq = 0;
const send = (msg) => {
  const body = JSON.stringify({ jsonrpc: "2.0", ...msg });
  child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
};
const request = (method, params) => { send({ id: ++seq, method, params }); return seq; };
const notify = (method, params) => send({ method, params });

let lastMessageAt = Date.now();
let diagnostics = 0;
let buf = Buffer.alloc(0);
const waiters = new Map();

child.stdout.on("data", (d) => {
  buf = Buffer.concat([buf, d]);
  for (;;) {
    const head = buf.indexOf("\r\n\r\n");
    if (head === -1) return;
    const m = buf.slice(0, head).toString().match(/Content-Length: (\d+)/i);
    if (!m) return;
    const len = Number(m[1]);
    if (buf.length < head + 4 + len) return;
    const raw = buf.slice(head + 4, head + 4 + len).toString();
    buf = buf.slice(head + 4 + len);
    lastMessageAt = Date.now();
    let msg;
    try { msg = JSON.parse(raw); } catch { continue; }
    if (msg.method === "textDocument/publishDiagnostics") diagnostics++;
    if (msg.id !== undefined && msg.method) send({ id: msg.id, result: null });
    if (msg.id !== undefined && waiters.has(msg.id)) { waiters.get(msg.id)(msg); waiters.delete(msg.id); }
  }
});

const await_ = (id, ms) => new Promise((res) => {
  const t = setTimeout(() => { waiters.delete(id); res(null); }, ms);
  waiters.set(id, (m) => { clearTimeout(t); res(m); });
});

const peak = { pss: 0, rss: 0, procs: 0 };
const sampler = setInterval(() => {
  const s = sampleTree(child.pid);
  if (s.pss > peak.pss) Object.assign(peak, s);
}, 400);

const t0 = Date.now();

const capabilities = {
  workspace: { configuration: true, didChangeConfiguration: {}, workspaceFolders: true },
  textDocument: {
    synchronization: { didSave: true, dynamicRegistration: true },
    publishDiagnostics: { relatedInformation: true },
    hover: { contentFormat: ["plaintext"] },
  },
};

const rootUri = pathToFileURL(root).href;
const initId = request("initialize", {
  processId: process.pid,
  rootPath: root,
  rootUri,
  capabilities,
  workspaceFolders: [{ uri: rootUri, name: "probe" }],
  initializationOptions: {},
});

const langOf = (f) =>
  f.endsWith(".py") ? "python"
  : f.endsWith(".tsx") ? "typescriptreact"
  : f.endsWith(".jsx") ? "javascriptreact"
  : f.endsWith(".js") || f.endsWith(".mjs") || f.endsWith(".cjs") ? "javascript"
  : "typescript";

(async () => {
  const init = await await_(initId, 60000);
  if (!init) {
    clearInterval(sampler);
    child.kill("SIGKILL");
    console.error(`${label}: initialize timed out\n${stderrTail}`);
    process.exit(67);
  }
  notify("initialized", {});
  notify("workspace/didChangeConfiguration", { settings: {} });

  for (const f of files) {
    let text;
    try { text = readFileSync(f, "utf8"); } catch { continue; }
    notify("textDocument/didOpen", {
      textDocument: { uri: pathToFileURL(f).href, languageId: langOf(f), version: 1, text },
    });
  }

  const deadline = Date.now() + settleMs;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 500));
    if (Date.now() - lastMessageAt > quietMs) break;
  }

  const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
  clearInterval(sampler);
  const final = sampleTree(child.pid);
  if (final.pss > peak.pss) Object.assign(peak, final);

  try { notify("shutdown", {}); notify("exit", {}); } catch {}
  setTimeout(() => child.kill("SIGKILL"), 1500).unref();

  const out = {
    label,
    files: files.length,
    peak_pss_mb: Math.round(peak.pss),
    peak_rss_mb: Math.round(peak.rss),
    procs: peak.procs,
    diagnostics,
    seconds: Number(elapsed),
  };
  if (asJson) console.log(JSON.stringify(out));
  else
    console.log(
      `${label.padEnd(30)} PSS ${String(out.peak_pss_mb).padStart(5)} MB   ` +
        `RSS ${String(out.peak_rss_mb).padStart(5)} MB   ` +
        `${out.procs} proc  ${String(out.files).padStart(3)} files  ` +
        `${out.diagnostics} diag  ${out.seconds}s`,
    );
  process.exit(0);
})();
