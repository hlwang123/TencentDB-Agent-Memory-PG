const fs = require("fs");
const path = "/app/src/core/store/pg-store.ts";
let s = fs.readFileSync(path, "utf8");

// Fix 1: Change type-only import to value import
s = s.replace(
  'import type { Pool, PoolClient } from "pg";',
  'import { Pool, type PoolClient } from "pg";'
);

// Fix 2: Remove the require line
s = s.replace(
  '    const { Pool: PgPool } = require("pg") as typeof import("pg");\n',
  ''
);

// Fix 3: Change PgPool to Pool in constructor
s = s.replace('this.pool = new PgPool(', 'this.pool = new Pool(');

fs.writeFileSync(path, s);
console.log("Patched pg-store.ts successfully");
console.log("Line 2:", s.split("\n")[1]);
console.log("Constructor area:", s.split("\n").slice(58, 68).join("\n"));
