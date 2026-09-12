const fs = require("fs");
const p = "/app/src/gateway/server.ts";
let s = fs.readFileSync(p, "utf8");

s = s.replace(
  'const storeModeOverride = process.env.STORE_MODE === "sqlite" || process.env.STORE_MODE === "tcvdb"\n      ? (process.env.STORE_MODE as "sqlite" | "tcvdb")\n      : undefined;',
  'const storeModeOverride = process.env.STORE_MODE === "sqlite" || process.env.STORE_MODE === "tcvdb" || process.env.STORE_MODE === "postgres"\n      ? (process.env.STORE_MODE as "sqlite" | "tcvdb" | "postgres")\n      : undefined;'
);

fs.writeFileSync(p, s);
console.log("server.ts patched OK");
