// Usage: node hash-doc.mjs <file>
// Prints the SHA-256 digest of a document as a 0x-prefixed bytes32,
// the value stored as `docHash` on-chain. Same result as `sha256sum <file>`.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const file = process.argv[2];
if (!file) {
  console.error("Usage: node hash-doc.mjs <file>");
  process.exit(1);
}
console.log("0x" + createHash("sha256").update(readFileSync(file)).digest("hex"));
