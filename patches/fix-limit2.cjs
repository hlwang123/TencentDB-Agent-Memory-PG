const fs = require("fs");
const path = "/app/src/core/store/pg-store.ts";
let s = fs.readFileSync(path, "utf8");

// Fix remaining LIMIT/OFFSET with ++i pattern
// Pattern: LIMIT $" + (++i) + " OFFSET $" + (++i)
s = s.replace(
  /LIMIT \$" \+\+\+i\) \+ " OFFSET \$" \+\+\+i\)/g,
  'LIMIT $" + (++i) + "::int OFFSET $" + (++i) + "::int"'
);

// Also try with different spacing
s = s.replace(
  /LIMIT \$"\s*\+\s*\(\+\+i\)\s*\+\s*" OFFSET \$"\s*\+\s*\(\+\+i\)/g,
  'LIMIT $" + (++i) + "::int OFFSET $" + (++i) + "::int"'
);

fs.writeFileSync(path, s);

// Verify
const lines = s.split("\n");
const remaining = lines.filter(l => l.includes("LIMIT") && !l.includes("::int"));
console.log("Remaining LIMIT lines without ::int:", remaining.length);
remaining.forEach(l => console.log("  " + l.trim()));

const patched = lines.filter(l => l.includes("LIMIT") && l.includes("::int"));
console.log("\nPatched LIMIT lines with ::int:", patched.length);
