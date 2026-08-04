#!/usr/bin/env node
// Drive an opencode session through a long, multi-round agent task while
// ./run measure samples the box. The session must already exist.
//
//   node drive-agent-loop.mjs <session_id> <repetitions> "prompt"
import { request } from "node:http";

const [sid, repeatStr, ...rest] = process.argv.slice(2);
const repeat = Number(repeatStr) || 1;
const prompt = rest.join(" ");
if (!sid || !prompt) {
  console.error("usage: drive-agent-loop.mjs <sessionID> <repetitions> <prompt>");
  process.exit(64);
}

function drive(text) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      agent: "build",
      model: { providerID: "opencode", modelID: "big-pickle" },
      parts: [{ type: "text", text }],
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
        if (res.statusCode !== 200) {
          reject(new Error(`status ${res.statusCode}`));
          return;
        }
        let buf = "";
        res.on("data", (d) => (buf += d));
        res.on("end", () => {
          try {
            const j = JSON.parse(buf);
            const text = (j.parts || []).filter((p) => p.type === "text").map((p) => p.text).join("\n");
            resolve(text.slice(0, 600));
          } catch (e) {
            resolve(`<parse error: ${e.message}>`);
          }
        });
      },
    );
    req.on("error", reject);
    req.end(body);
  });
}

for (let i = 0; i < repeat; i++) {
  const t0 = Date.now();
  try {
    const out = await drive(i === 0 ? prompt : `Continue. Round ${i + 1}. ${prompt}`);
    console.log(`round ${i + 1}: ${((Date.now() - t0) / 1000).toFixed(1)}s -> ${out.slice(0, 200)}`);
  } catch (e) {
    console.error(`round ${i + 1} failed: ${e.message}`);
    process.exit(1);
  }
}
console.log("ALL_DONE");