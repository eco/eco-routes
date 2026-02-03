# Polymer Proof Structure Analysis

## Transaction Details

- **Optimism TX:** https://optimistic.etherscan.io/tx/0x46addebff4fecfd216db2177cfd5e2438b2baeff7cbda6117facbae2bae3879a
- **Function Called:** `validate(bytes proof)` on PolymerProver
- **Contract:** 0xe6FEbF8C8bf6366eF6fE7337b0b5B394D46d9fc6

## Proof Bytes Breakdown

The proof is **1198 bytes (0x4ae)** in length.

### Structure

Based on the PolymerProver contract, the proof bytes are passed to `CrossL2ProverV2.validateEvent(proof)` which returns:

- `uint32 destinationChainId` - The chain where this proof is being validated (Optimism = 10)
- `address emittingContract` - The address that emitted the original event (should be a PolymerProver on another chain)
- `bytes topics` - Event topics (64 bytes: event signature + indexed params)
- `bytes unindexedData` - The encoded proof data containing intent hashes and claimants

### Expected Event Being Proven

The proof should prove an `IntentFulfilledFromSource` event from a PolymerProver on Mainnet (chain ID 1):

```solidity
event IntentFulfilledFromSource(uint64 indexed source, bytes encodedProofs);
```

Where:

- `source` = Chain ID where fulfillment happened (indexed topic)
- `encodedProofs` = Bytes containing:
  - 8-byte chain ID prefix (destination chain ID)
  - Multiple 64-byte pairs of (intentHash, claimant)

### To Simulate on Mainnet

For a Tenderly simulation on Mainnet, you would call the **PolymerProver.validate(bytes proof)** function on Mainnet with this same proof bytes.

**Mainnet PolymerProver Address:** 0xCf05B59f445a0Bb49061B1919bA3c7577034cC6F

The simulation would:

1. Call `CrossL2ProverV2.validateEvent(proof)` to extract the event data
2. Verify the event signature matches `keccak256("IntentFulfilledFromSource(uint64,bytes)")`
3. Verify the emitting contract is whitelisted
4. Extract intent hashes and claimants from the proof data
5. Store them in the `provenIntents` mapping
6. Emit `IntentProven` events for each intent

## Proof Bytes (Full)

```
0x44f8675a222c0c14c7772adca148f964f10d6f35a47cbb698d9b4d480805af59e3de76
ae339d4bcb3001841f1b53586b355703ec0f35fbc62abfccd47aaef2281e1b811c2219
6bbaccd90a8d274788afbedc2f72c3d89886629ec78498d905fe1b2b6653dc00000000
003e0e4900000000047e8f2d000000a50000001c020174b91a0c7f84b3c2316330c50
04d963647571bc055d493dde4de24066db29a754b1e9dc5dedf7084850c4abf76c230
46ba9dad6b1d000000000000000000000000000000000000000000000000000000000
000000a0000000000000000000000000000000000000000000000000000000000000020
0000000000000000000000000000000000000000000000000000000000000048000000
002b6653dcaaaec06f81c6fa8e700ce3d6399446c24a2c4c1ac25db4d8644d7fea18e
b3d0700000000000000000000000004eb5e1c0952900d3b92a6101e10698a09497d95
0000000000000000000000000000000000000000000000001309000292b9f003342a2a
020492b9f00320b553b3d1f5ed30e4077161df344d059ee64ed76f46e7ee6b9e97fa0
862e61a4e20092a040692b9f003202030ce3c2131956e6b6db2db9eb8ec6697f27da4
eb6feefffe640376a7f00d01932a2a060a92b9f0032071c481922262e054412ac31dc
49f2e01e875b2badd113cdd0853f53ca720daad202a2a081292b9f00320f85eb0fb40
ed6ce15e47e5b6b278ef6a5f894d9320d6dcd7f789ffddc43055c0202a2a0a3092b9f
00320e0dde964e73b34be96bb0c26096ded8a303ead4eb23acfdc0e76409d2ffb425a
202a2a0c7092b9f00320170244544a9b17e5a7f2ca23225537c2014c3535d7cfa20d4
a85668abcd06958202b2b0eb00192b9f00320c17c2638d99477c5dcb4334fc82faf81
438955273d25a2555453e5e3472052c8202b2b10b00292b9f003201a9b7990baca6f2
c759d660e8af2a62684b5cfd0b1164f5dc17a9deaecbc1efe202b2b12b00492b9f003
204eed812a6f0889e8363fee84b7ee772640fbb963cbe0e2c9f7f217d9ec240507202
b2b14e80792b9f003201ca1f6c466fe728596538b6230a67ac4d03dbbc379f8593ae8
42931af0162e72200a2b16921092b9f00320207a3e6c170162d4de2b2a5a0d3b8ee6f
e5b11dd5c78d3e30bb5d993669eaee6fe2b2b1ae82492b9f003203c4620de841b4a35
a8e14458b9719e775225033034c28c1acf8c7226b7f3b3c3200a2b1c885392b9f0032
020e5188ca83eea419a23986736d5ada8a9254ec954d26bae7d53fa12b46e637c162c
2c1eda860192b9f00320db6a3c8cdcb6db613321df0eb2dd0dee0fa28a20ae287dfdd
91db43711b63ce7202c2c20cea50292b9f00320641d4c9f447140ed141b05bf1f5bbb
2f30f36fc7c2a5f96c757e6c519c42e889202c2c22f2fd0492b9f00320f9c75a34b1d
26d16aa9e1e23d1ccfadb86936507f5ddf880ec2a9db4710f7e06200b2c24b8920a92
b9f0032020336ab2b8bfefb1ff82de8c1df737d1b7ea703e022f162cdd4174c681dd8
9f7302c2c28b6a81392b9f0032010ab8b926480418d1852ef4ea801494cf0d6461f1c
39597d0cfcbe6ab232dd96200b2c2ab8ad2a92b9f0032020b54376e6dcf5c662d54f9
7b7024a51636e93b5b05fac2e6ccd170a0060f8fab9
```

## For Tenderly Simulation

**Contract:** `0xCf05B59f445a0Bb49061B1919bA3c7577034cC6F` (Mainnet PolymerProver)

**Function:** `validate(bytes proof)`

**Calldata:**

```
0xc16e50ef  // Function selector for validate(bytes)
0000000000000000000000000000000000000000000000000000000000000020  // Offset to bytes
00000000000000000000000000000000000000000000000000000000000004ae  // Length (1198 bytes)
[...proof bytes above...]
```

Note: The CrossL2ProverV2 on Mainnet will need to be at the expected address and properly configured to validate proofs from Optimism events.
