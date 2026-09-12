const fs = require("fs");
const path = "/app/src/core/store/pg-store.ts";
let s = fs.readFileSync(path, "utf8");

let fixes = 0;

// Fix: timestamp: m.timestamp ?? 0  ->  timestamp: Number(m.timestamp) || 0
const old1 = "timestamp: m.timestamp ?? 0";
const new1 = "timestamp: Number(m.timestamp) || 0";
const c1 = (s.match(/timestamp: m\.timestamp \?\? 0/g) || []).length;
s = s.replaceAll("timestamp: m.timestamp ?? 0", "timestamp: Number(m.timestamp) || 0");
if (c1 > 0) { console.log(`Fix: ${c1}x 'timestamp: m.timestamp ?? 0' -> 'Number(m.timestamp) || 0'`); fixes += c1; }

// Fix: timestamp: row.timestamp ?? 0  ->  timestamp: Number(row.timestamp) || 0
const old2 = "timestamp: row.timestamp ?? 0";
const new2 = "timestamp: Number(row.timestamp) || 0";
const c2 = (s.match(/timestamp: row\.timestamp \?\? 0/g) || []).length;
s = s.replaceAll("timestamp: row.timestamp ?? 0", "timestamp: Number(row.timestamp) || 0");
if (c2 > 0) { console.log(`Fix: ${c2}x 'timestamp: row.timestamp ?? 0' -> 'Number(row.timestamp) || 0'`); fixes += c2; }

fs.writeFileSync(path, s);
console.log(`\nTotal fixes: ${fixes}`);

// Verify no remaining unconverted timestamp references
const remaining = s.match(/timestamp: [a-z_]+\.timestamp/g);
if (remaining) {
  console.log("Remaining unconverted:", remaining);
} else {
  console.log("All timestamp references converted!");
}
