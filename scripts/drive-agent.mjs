#!/usr/bin/env node
// Drive an opencode session to do real work — measures tool subprocesses and LSPs.
//
// Usage: node drive-agent.mjs <session_id> "prompt text"
import { request } from "node:http";

const [sid, prompt] = process.argv.slice(2);
if (!sid || !prompt) {
  console.error("usage: drive-agent.mjs <sessionID> <prompt>");
  process.exit(64);
}

const body = JSON.stringify({
  agent: "build",
  model: { providerID: "opencode", modelID: "big-pickle" },
  parts: [{ type: "text", text: prompt }],
});

const req = request(
  {
    method: "POST",
    host: "127.0.0.1",
    port: 4098,
    path: `/session/${sid}/message`,
    headers: {
      Authorization: `Basic ${Buffer.from("opencode:x").toString("base64")}`,
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
    },
  },
  (res) => {
    process.stderr.write(`status: ${res.statusCode}\n`);
    res.on("data", (d) => process.stdout.write(d));
    res.on("end", () => {
      if (res.statusCode !== 200) process.exit(1);
    });
  },
);
req.on("error", (e) => {
  console.error(`request error: ${e.message}`);
  process.exit(1);
});
req.end(body);