const fs = require("fs");

// ── Patch config.ts ──
const configPath = "/app/src/config.ts";
let config = fs.readFileSync(configPath, "utf8");

// 1. Add "postgres" to StoreBackend type
config = config.replace(
  'export type StoreBackend = "sqlite" | "tcvdb";',
  'export type StoreBackend = "sqlite" | "tcvdb" | "postgres";'
);

// 2. Add PostgresConfig interface after TcvdbConfig
config = config.replace(
  'export type StoreBackend = "sqlite" | "tcvdb" | "postgres";',
  'export type StoreBackend = "sqlite" | "tcvdb" | "postgres";\n\nexport interface PostgresConfig {\n  connectionString: string;\n  schema?: string;\n}'
);

// 3. Add postgres field to MemoryTdaiConfig
config = config.replace(
  '  storeBackend: StoreBackend;\n  /** Tencent Cloud VectorDB configuration',
  '  storeBackend: StoreBackend;\n  postgres: PostgresConfig;\n  /** Tencent Cloud VectorDB configuration'
);

// 4. Fix storeBackend parsing
config = config.replace(
  'const storeBackend: StoreBackend = storeBackendRaw === "tcvdb" ? "tcvdb" : "sqlite";',
  'const storeBackend: StoreBackend = storeBackendRaw === "tcvdb" ? "tcvdb" : storeBackendRaw === "postgres" ? "postgres" : "sqlite";'
);

// 5. Add postgres group parsing after tcvdb group
config = config.replace(
  'const tcvdbGroup = obj(c, "tcvdb");',
  'const tcvdbGroup = obj(c, "tcvdb");\n  const postgresGroup = obj(c, "postgres");'
);

// 6. Add postgres config to return object (after tcvdb block)
config = config.replace(
  'caPemPath: str(tcvdbGroup, "caPemPath") || undefined,\n    },',
  'caPemPath: str(tcvdbGroup, "caPemPath") || undefined,\n    },\n    postgres: {\n      connectionString: str(postgresGroup, "connectionString") ?? "",\n      schema: str(postgresGroup, "schema") ?? undefined,\n    },'
);

fs.writeFileSync(configPath, config);
console.log("config.ts patched OK");

// ── Patch factory.ts ──
const factoryPath = "/app/src/core/store/factory.ts";
let factory = fs.readFileSync(factoryPath, "utf8");

// Add import
factory = factory.replace(
  'import { TcvdbMemoryStore } from "./tcvdb.js";',
  'import { TcvdbMemoryStore } from "./tcvdb.js";\nimport { PgMemoryStore } from "./pg-store.js";'
);

// Add postgres case before the default case
factory = factory.replace(
  '    case "sqlite"\n    default:',
  '    case "postgres": {\n      const pgCfg = config.postgres;\n      if (!pgCfg.connectionString) {\n        throw new Error(TAG + " PostgreSQL backend requires postgres.connectionString");\n      }\n      const dims = config.embedding.dimensions;\n      const store = new PgMemoryStore({\n        connectionString: pgCfg.connectionString,\n        dimensions: dims,\n        logger,\n        schema: pgCfg.schema,\n      });\n      logger?.debug?.(TAG + " Store created: backend=postgres, dimensions=" + dims);\n      return {\n        store,\n        embedding: embeddingService as unknown as IEmbeddingService,\n        bm25Encoder,\n        storeSnapshot: { type: "postgres" as const, postgresConnection: pgCfg.connectionString },\n      };\n    }\n\n    case "sqlite"\n    default:'
);

// Fix: the embedding service creation needs to happen before the switch
// Currently it's inside the sqlite case. Let me move it up.
// Actually looking at the code, embedding service is created inside the sqlite case.
// For postgres, we also need it. Let me check...
// The factory creates embedding service only in the sqlite case. For postgres,
// we need the same embedding service. Let me add it to the postgres case.
// Actually, let me just create the embedding service before the switch.
// But that would change the existing behavior. Let me just duplicate the
// embedding service creation in the postgres case.

// Actually, looking more carefully, the embedding service creation is inside
// the sqlite case. For the postgres case, I'll just use the same logic.
// Let me update the postgres case to create the embedding service.

factory = factory.replace(
  '    case "postgres": {\n      const pgCfg = config.postgres;\n      if (!pgCfg.connectionString) {\n        throw new Error(TAG + " PostgreSQL backend requires postgres.connectionString");\n      }\n      const dims = config.embedding.dimensions;\n      const store = new PgMemoryStore({\n        connectionString: pgCfg.connectionString,\n        dimensions: dims,\n        logger,\n        schema: pgCfg.schema,\n      });\n      logger?.debug?.(TAG + " Store created: backend=postgres, dimensions=" + dims);\n      return {\n        store,\n        embedding: embeddingService as unknown as IEmbeddingService,\n        bm25Encoder,\n        storeSnapshot: { type: "postgres" as const, postgresConnection: pgCfg.connectionString },\n      };\n    }',
  '    case "postgres": {\n      const pgCfg = config.postgres;\n      if (!pgCfg.connectionString) {\n        throw new Error(TAG + " PostgreSQL backend requires postgres.connectionString");\n      }\n      let pgEmbeddingService: EmbeddingService | undefined;\n      if (config.embedding.enabled && config.embedding.provider !== "local" && config.embedding.provider !== "none" && config.embedding.apiKey) {\n        pgEmbeddingService = createEmbeddingService({\n          provider: config.embedding.provider,\n          baseUrl: config.embedding.baseUrl,\n          apiKey: config.embedding.apiKey,\n          model: config.embedding.model,\n          dimensions: config.embedding.dimensions,\n          sendDimensions: config.embedding.sendDimensions,\n          maxInputChars: config.embedding.maxInputChars,\n        }, logger);\n      }\n      const pgDims = config.embedding.dimensions;\n      const store = new PgMemoryStore({\n        connectionString: pgCfg.connectionString,\n        dimensions: pgDims,\n        logger,\n        schema: pgCfg.schema,\n      });\n      logger?.debug?.(TAG + " Store created: backend=postgres, dimensions=" + pgDims);\n      return {\n        store,\n        embedding: pgEmbeddingService as unknown as IEmbeddingService,\n        bm25Encoder,\n        storeSnapshot: { type: "postgres" as const, postgresConnection: pgCfg.connectionString },\n      };\n    }'
);

fs.writeFileSync(factoryPath, factory);
console.log("factory.ts patched OK");

// ── Patch store-pool.ts ──
const poolPath = "/app/src/core/store/store-pool.ts";
let pool = fs.readFileSync(poolPath, "utf8");

// Add postgres to StoreMode
pool = pool.replace(
  'export type StoreMode = "sqlite" | "tcvdb";',
  'export type StoreMode = "sqlite" | "tcvdb" | "postgres";'
);

// Add import for PgMemoryStore
pool = pool.replace(
  'import { TcvdbMemoryStore } from "./tcvdb.js";',
  'import { TcvdbMemoryStore } from "./tcvdb.js";\nimport { PgMemoryStore } from "./pg-store.js";'
);

// Add postgres store creation method and handle in getStore
// Add createPostgresStore after createSqliteStore method
pool = pool.replace(
  '  private createTcvdbStore(vdbConfig: VdbConfig): PooledStore {',
  '  private createPostgresStore(instanceId: string): PooledStore {\n    let embeddingService: EmbeddingService | undefined;\n    const embCfg = this.memoryCfg.embedding;\n    if (embCfg.enabled && embCfg.provider !== "local" && embCfg.provider !== "none" && embCfg.apiKey) {\n      embeddingService = createEmbeddingService({\n        provider: embCfg.provider,\n        baseUrl: embCfg.baseUrl,\n        apiKey: embCfg.apiKey,\n        model: embCfg.model,\n        dimensions: embCfg.dimensions,\n        sendDimensions: embCfg.sendDimensions,\n        maxInputChars: embCfg.maxInputChars,\n      }, this.logger as StoreLogger);\n    }\n    const dims = embCfg.dimensions ?? 0;\n    const store = new PgMemoryStore({\n      connectionString: this.memoryCfg.postgres.connectionString,\n      dimensions: dims,\n      logger: this.logger as StoreLogger,\n      schema: this.memoryCfg.postgres.schema,\n    });\n    return {\n      store,\n      embedding: (embeddingService ?? new NoopEmbeddingService()) as unknown as EmbeddingService,\n      bm25Encoder: this.sharedBm25Encoder,\n    };\n  }\n\n  private createTcvdbStore(vdbConfig: VdbConfig): PooledStore {'
);

// Update getStore to handle postgres mode
pool = pool.replace(
  'const pooledStore = this.mode === "tcvdb" && vdbConfig\n      ? this.createTcvdbStore(vdbConfig)\n      : this.createSqliteStore(instanceId);',
  'const pooledStore = this.mode === "tcvdb" && vdbConfig\n      ? this.createTcvdbStore(vdbConfig)\n      : this.mode === "postgres"\n      ? this.createPostgresStore(instanceId)\n      : this.createSqliteStore(instanceId);'
);

// Update storeDesc
pool = pool.replace(
  'const storeDesc = this.mode === "tcvdb" && vdbConfig\n      ? `${vdbConfig.url} / ${vdbConfig.database}`\n      : `sqlite @ ${this.getSqlitePath(instanceId)}`;',
  'const storeDesc = this.mode === "tcvdb" && vdbConfig\n      ? `${vdbConfig.url} / ${vdbConfig.database}`\n      : this.mode === "postgres"\n      ? `postgres @ ${this.memoryCfg.postgres.connectionString}`\n      : `sqlite @ ${this.getSqlitePath(instanceId)}`;'
);

fs.writeFileSync(poolPath, pool);
console.log("store-pool.ts patched OK");
console.log("All patches applied successfully!");
