const fs = require("fs");
const p = "/app/src/utils/manifest.ts";
let m = fs.readFileSync(p, "utf8");
// Add postgres field to ManifestStoreInfo
m = m.replace(
  "  tcvdb?: {\n    url: string;\n    database: string;\n    alias?: string;\n  };\n}",
  "  tcvdb?: {\n    url: string;\n    database: string;\n    alias?: string;\n  };\n  postgres?: {\n    connectionString: string;\n  };\n}"
);
fs.writeFileSync(p, m);
console.log("manifest.ts patched: added postgres field to ManifestStoreInfo");

// Also check if buildStoreInfo has the postgres case
if (m.includes('snapshot.type === "postgres"')) {
  console.log("buildStoreInfo already has postgres case");
} else {
  console.log("WARNING: buildStoreInfo missing postgres case!");
}
