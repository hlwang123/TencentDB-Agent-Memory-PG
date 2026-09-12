const fs = require("fs");

// Fix config.ts mangled lines
const configPath = "/app/src/config.ts";
let config = fs.readFileSync(configPath, "utf8");

// Fix StoreBackend type (was mangled by earlier sed)
config = config.replace(
  /export type StoreBackend = .*/m,
  'export type StoreBackend = "sqlite" | "tcvdb" | "postgres";'
);

// Fix storeBackend parsing (was mangled by earlier sed)
config = config.replace(
  /const storeBackend: StoreBackend = .*/m,
  '  const storeBackend: StoreBackend = storeBackendRaw === "tcvdb" ? "tcvdb" : storeBackendRaw === "postgres" ? "postgres" : "sqlite";'
);

fs.writeFileSync(configPath, config);

// Fix manifest.ts StoreConfigSnapshot type
const manifestPath = "/app/src/utils/manifest.ts";
let manifest = fs.readFileSync(manifestPath, "utf8");
manifest = manifest.replace(
  'type: "sqlite" | "tcvdb";',
  'type: "sqlite" | "tcvdb" | "postgres";'
);
// Add postgresConnection field
manifest = manifest.replace(
  '  tcvdbAlias?: string;\n}',
  '  tcvdbAlias?: string;\n  postgresConnection?: string;\n}'
);
// Add postgres case in buildStoreInfo
manifest = manifest.replace(
  '  } else {\n    info.tcvdb = {',
  '  } else if (snapshot.type === "postgres") {\n    info.postgres = { connectionString: snapshot.postgresConnection ?? "" };\n  } else {\n    info.tcvdb = {'
);
fs.writeFileSync(manifestPath, manifest);

console.log("Fixed config.ts and manifest.ts");

// Verify
const verify = fs.readFileSync(configPath, "utf8");
const lines = verify.split("\n");
for (let i = 0; i < lines.length; i++) {
  if (lines[i].includes("StoreBackend") || lines[i].includes("storeBackend")) {
    console.log((i+1) + ": " + lines[i]);
  }
}
