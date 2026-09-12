const fs = require("fs");
const path = "/app/src/core/store/pg-store.ts";
let s = fs.readFileSync(path, "utf8");

// Fix all "LIMIT $N" to "LIMIT $N::int" and "OFFSET $N" to "OFFSET $N::int"
// But we need to be careful with dynamic parameter numbering

// Fix simple static LIMIT $N patterns
s = s.replace(/LIMIT \$3"/g, 'LIMIT $3::int"');
s = s.replace(/LIMIT \$2"/g, 'LIMIT $2::int"');

// Fix dynamic LIMIT $" + (expr) patterns
s = s.replace(/LIMIT \$" \+ \(iso\.params\.length \+ 2\)/g, 'LIMIT $" + (iso.params.length + 2) + "::int"');
s = s.replace(/LIMIT \$" \+\(\+\+i\)/g, 'LIMIT $" + (++i) + "::int"');
s = s.replace(/OFFSET \$" \+\(\+\+i\)/g, 'OFFSET $" + (++i) + "::int"');

fs.writeFileSync(path, s);

// Verify
const lines = s.split("\n");
const limitLines = lines.filter(l => l.includes("LIMIT") || l.includes("OFFSET"));
console.log("Lines with LIMIT/OFFSET after patch:");
limitLines.forEach(l => console.log("  " + l.trim()));

console.log("\nDone. Total patches applied.");
