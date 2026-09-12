import os
import sys

# 修复 heredoc 转义导致的 connectionString 格式破损（一次性修复脚本）。
# 用法：python fix-yaml.py <tdai-gateway.yaml 路径>
p = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GATEWAY_YAML_PATH")
if not p:
    print("用法: python fix-yaml.py <tdai-gateway.yaml 路径>")
    sys.exit(1)

conn = os.environ.get("PG_CONNECTION_STRING", "")
with open(p, "r") as f:
    c = f.read()

# Fix the mangled postgres section
c = c.replace(
    '  postgres:\\n    connectionString: " ' + conn,
    '  postgres:\n    connectionString: "' + conn + '"'
)

with open(p, "w") as f:
    f.write(c)

# Verify
with open(p, "r") as f:
    for i, line in enumerate(f, 1):
        if "storeBackend" in line or "postgres" in line or "connectionString" in line:
            print(f"{i}: {line}", end="")
print("\nDone!")
