// Independent fixtures: run from eco-routes with @solana/web3.js and @solana/spl-token available.
// Example: NODE_PATH=../eco-solver/node_modules node test/chain/testdata/generate-solana-vectors.cjs
// Writes JSON to stdout only. The vault golden is read from the pinned eco-routes-svm commit.
const { execFileSync } = require("node:child_process")
const crypto = require("node:crypto")
const assert = require("node:assert/strict")
const { PublicKey } = require("@solana/web3.js")
const {
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} = require("@solana/spl-token")
const { keccak256, encodePacked } = require("viem")
const svmRef = "95c728850955d3c9aa7c62ba08a87db5be89e220"
const goldenPath =
  "programs/portal/src/state/testdata/vault_pda_deterministic.golden"
const portal = new PublicKey("EcooswwC1NggsckZyF5SeAL9WsgJs3UhPbrqY1apV73F")
const mint = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
const hex = (bytes) => "0x" + Buffer.from(bytes).toString("hex")
const derive = (hash) => {
  const [vault, vaultBump] = PublicKey.findProgramAddressSync(
    [Buffer.from("vault"), hash],
    portal,
  )
  const [ata, ataBump] = PublicKey.findProgramAddressSync(
    [vault.toBuffer(), TOKEN_PROGRAM_ID.toBuffer(), mint.toBuffer()],
    ASSOCIATED_TOKEN_PROGRAM_ID,
  )
  return {
    intentHash: hex(hash),
    vault: hex(vault.toBuffer()),
    vaultBump,
    ata: hex(ata.toBuffer()),
    ataBump,
  }
}
// SVM state.rs test: keccak(uint64_be(1000) || [6;32] || [8;32]).
const golden = derive(
  Buffer.from(
    "657cfbe2261fb6d4304823599e43f3b5be763e4f52490258b9b7f0dbf2f62047",
    "hex",
  ),
)
const [expectedVault, expectedBump] = JSON.parse(
  execFileSync(
    "git",
    [
      "-C",
      process.argv[2] || "../eco-routes-svm",
      "show",
      `${svmRef}:${goldenPath}`,
    ],
    { encoding: "utf8" },
  ),
)
assert.equal(golden.vault, hex(expectedVault))
assert.equal(golden.vaultBump, expectedBump)
const vectors = Array.from({ length: 128 }, (_, i) =>
  derive(
    crypto
      .createHash("sha256")
      .update("eco-routes-pda-vector-" + i)
      .digest(),
  ),
)
const curve = Array.from({ length: 128 }, (_, i) => {
  const point = crypto
    .createHash("sha256")
    .update("eco-routes-curve-vector-" + i)
    .digest()
  return { point: hex(point), onCurve: PublicKey.isOnCurve(point) }
})
const borsh = (amount) => {
  const creator = Buffer.alloc(32)
  creator[31] = 3
  const prover = Buffer.alloc(32)
  prover[31] = 7
  const encodedAmount = Buffer.alloc(8)
  encodedAmount.writeBigUInt64LE(BigInt(amount))
  const reward = Buffer.concat([
    Buffer.from("0094357700000000", "hex"),
    creator,
    prover,
    Buffer.alloc(8),
    Buffer.from("01000000", "hex"),
    mint.toBuffer(),
    encodedAmount,
  ])
  const hash = keccak256(
    encodePacked(
      ["uint64", "bytes32", "bytes32"],
      [1000n, keccak256("0x010203"), keccak256(reward)],
    ),
  )
  return derive(Buffer.from(hash.slice(2), "hex"))
}
console.log(
  JSON.stringify(
    {
      provenance: {
        svmRef,
        golden: goldenPath,
        generator: "@solana/web3.js 1.98.4; @solana/spl-token 0.4.13",
      },
      portal: hex(portal.toBuffer()),
      mint: hex(mint.toBuffer()),
      tokenProgram: hex(TOKEN_PROGRAM_ID.toBuffer()),
      golden,
      borsh1000: borsh(1000),
      borsh1001: borsh(1001),
      vectors,
      curve,
    },
    null,
    2,
  ),
)
