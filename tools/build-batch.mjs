// Usage: node build-batch.mjs <package.json> [out.json]
//
// Input: a JSON array of task cards in one maintenance package:
//   [{ "partId": "0x..", "taskRef": "C-CHK-2026-05-T001", "docHash": "0x.." }, ...]
//
// Output: the Merkle root and leaf count to pass to BatchAnchor.anchorBatch(),
// plus a proof for every task card for BatchAnchor.verifyItem().
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { readFileSync, writeFileSync } from "node:fs";

const [input, output] = process.argv.slice(2);
if (!input) {
  console.error("Usage: node build-batch.mjs <package.json> [out.json]");
  process.exit(1);
}

const items = JSON.parse(readFileSync(input, "utf8"));
const values = items.map((i) => [i.partId, i.taskRef, i.docHash]);

// Must match BatchAnchor.leafHash: keccak256(bytes.concat(keccak256(abi.encode(partId, taskRef, docHash))))
const tree = StandardMerkleTree.of(values, ["bytes32", "string", "bytes32"]);

const result = {
  root: tree.root,
  leafCount: values.length,
  items: [...tree.entries()].map(([index, v]) => ({
    partId: v[0],
    taskRef: v[1],
    docHash: v[2],
    proof: tree.getProof(index),
  })),
};

const json = JSON.stringify(result, null, 2);
if (output) writeFileSync(output, json);
console.log(output ? `root ${result.root} (${result.leafCount} items) -> ${output}` : json);
