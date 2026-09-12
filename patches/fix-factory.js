const fs = require("fs");
const p = "/app/src/core/store/factory.ts";
let f = fs.readFileSync(p, "utf8");

// Check if postgres case already exists
if (f.includes('case "postgres"')) {
  console.log("postgres case already exists, skipping");
  process.exit(0);
}

// Insert postgres case before the sqlite/default case
const oldText = '    case "sqlite":\n    default: {';
const newText = `    case "postgres": {
      const pgCfg = config.postgres;
      if (!pgCfg || !pgCfg.connectionString) {
        throw new Error(TAG + " PostgreSQL backend requires postgres.connectionString");
      }
      let pgEmbeddingService: EmbeddingService | undefined;
      if (config.embedding.enabled && config.embedding.provider !== "local" && config.embedding.provider !== "none" && config.embedding.apiKey) {
        pgEmbeddingService = createEmbeddingService({
          provider: config.embedding.provider,
          baseUrl: config.embedding.baseUrl,
          apiKey: config.embedding.apiKey,
          model: config.embedding.model,
          dimensions: config.embedding.dimensions,
          sendDimensions: config.embedding.sendDimensions,
          maxInputChars: config.embedding.maxInputChars,
        }, logger);
      }
      const pgDims = config.embedding.dimensions;
      const store = new PgMemoryStore({
        connectionString: pgCfg.connectionString,
        dimensions: pgDims,
        logger,
        schema: pgCfg.schema,
      });
      logger?.debug?.(TAG + " Store created: backend=postgres, dimensions=" + pgDims);
      return {
        store,
        embedding: pgEmbeddingService as unknown as IEmbeddingService,
        bm25Encoder,
        storeSnapshot: { type: "postgres" as const, postgresConnection: pgCfg.connectionString },
      };
    }

    case "sqlite":
    default: {`;

if (f.includes(oldText)) {
  f = f.replace(oldText, newText);
  fs.writeFileSync(p, f);
  console.log("factory.ts: postgres case added OK");
} else {
  console.log("ERROR: could not find insertion point");
  console.log("Looking for:", JSON.stringify(oldText));
  // Try to find what's there
  const idx = f.indexOf('case "sqlite"');
  if (idx >= 0) {
    console.log("Found at index", idx, ":", JSON.stringify(f.substring(idx, idx + 50)));
  }
}
