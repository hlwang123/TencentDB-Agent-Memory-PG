const fs = require("fs");
const path = "/app/src/core/store/pg-store.ts";
let s = fs.readFileSync(path, "utf8");

let fixes = 0;

// Fix 1: Change buildIsoClause(filter, 2) to buildIsoClause(filter, 1) in search methods
// This fixes parameter numbering: $1=main param, $2+=isolation params
const before1 = s;
s = s.replace(/buildIsoClause\(filter, 2\)/g, "buildIsoClause(filter, 1)");
if (s !== before1) {
  const count = (before1.match(/buildIsoClause\(filter, 2\)/g) || []).length;
  console.log(`Fix 1: Changed ${count} buildIsoClause(filter, 2) -> buildIsoClause(filter, 1)`);
  fixes += count;
}

// Fix 2: Add ::vector cast to vector parameters in <=> comparisons
// Pattern: embedding <=> $1  ->  embedding <=> $1::vector
const before2 = s;
s = s.replace(/embedding <=> \$1/g, "embedding <=> $1::vector");
if (s !== before2) {
  const count = (before2.match(/embedding <=> \$1/g) || []).length;
  console.log(`Fix 2: Added ${count} ::vector casts to embedding <=> $1`);
  fixes += count;
}

fs.writeFileSync(path, s);
console.log(`\nTotal fixes applied: ${fixes}`);

// Verify
const lines = s.split("\n");
const searchLines = lines.filter(l => l.includes("searchL") && l.includes("pool.query"));
console.log("\nSearch method queries:");
searchLines.forEach((l, i) => console.log(`  [${i}] ${l.trim().substring(0, 200)}...`));
