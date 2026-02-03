// eslint-disable-next-line node/no-extraneous-import
import { describe, it } from 'mocha';
import { expect } from 'chai';
// eslint-disable-next-line node/no-extraneous-import
import { serialize, deserialize } from 'borsh';

/**
 * Borsh Encoding Verification Tests
 *
 * These tests verify that the Solidity encoding in DepositAddress._encodeRoute()
 * matches the Solana Route struct encoding using Borsh format.
 *
 * Critical: Solana's Call struct has NO value field (only target + data),
 * unlike the EVM Call struct which has target + data + value.
 */

// Define classes matching Solana's structs exactly
class TokenAmount {
  token: Uint8Array;  // 32-byte Pubkey
  amount: bigint;     // u64

  constructor(fields: { token: Uint8Array; amount: bigint }) {
    this.token = fields.token;
    this.amount = fields.amount;
  }
}

class Call {
  target: Uint8Array;  // 32-byte Bytes32
  data: Uint8Array;    // Vec<u8>

  constructor(fields: { target: Uint8Array; data: Uint8Array }) {
    this.target = fields.target;
    this.data = fields.data;
  }
}

class Route {
  salt: Uint8Array;           // 32 bytes
  deadline: bigint;           // u64
  portal: Uint8Array;         // 32 bytes
  nativeAmount: bigint;       // u64
  tokens: TokenAmount[];      // Vec<TokenAmount>
  calls: Call[];              // Vec<Call>

  constructor(fields: {
    salt: Uint8Array;
    deadline: bigint;
    portal: Uint8Array;
    nativeAmount: bigint;
    tokens: TokenAmount[];
    calls: Call[];
  }) {
    this.salt = fields.salt;
    this.deadline = fields.deadline;
    this.portal = fields.portal;
    this.nativeAmount = fields.nativeAmount;
    this.tokens = fields.tokens;
    this.calls = fields.calls;
  }
}

// Define borsh schemas as Maps (required by borsh library)
const schema = new Map([
  [TokenAmount, {
    kind: 'struct',
    fields: [
      ['token', [32]], // Fixed-size array of 32 bytes
      ['amount', 'u64']
    ]
  }],
  [Call, {
    kind: 'struct',
    fields: [
      ['target', [32]], // Fixed-size array of 32 bytes
      ['data', ['u8']]  // Variable-size array
    ]
  }],
  [Route, {
    kind: 'struct',
    fields: [
      ['salt', [32]],
      ['deadline', 'u64'],
      ['portal', [32]],
      ['nativeAmount', 'u64'],
      ['tokens', [TokenAmount]],
      ['calls', [Call]]
    ]
  }]
]);

describe('Borsh Encoding Verification', () => {
  it('should encode Route with correct byte length (204 bytes)', () => {
    // Create test data
    const salt = new Uint8Array(32).fill(1);
    const deadline = BigInt(604800); // 7 days
    const portal = new Uint8Array(32).fill(2);
    const destinationToken = new Uint8Array(32).fill(3);
    const destinationAddress = new Uint8Array(32).fill(4);
    const amount = BigInt(10_000_000_000); // 10,000 USDC (6 decimals)

    // Encode transfer data (destination + amount in little-endian)
    const transferData = new Uint8Array(40);
    transferData.set(destinationAddress, 0);

    // Convert amount to little-endian u64
    const amountLE = new Uint8Array(8);
    for (let i = 0; i < 8; i++) {
      amountLE[i] = Number((amount >> BigInt(i * 8)) & BigInt(0xFF));
    }
    transferData.set(amountLE, 32);

    const route = new Route({
      salt: salt,
      deadline: deadline,
      portal: portal,
      nativeAmount: BigInt(0),
      tokens: [new TokenAmount({
        token: destinationToken,
        amount: amount
      })],
      calls: [new Call({
        target: destinationToken,
        data: transferData
      })]
    });

    // Encode with borsh
    const encoded = Buffer.from(serialize(schema, route));

    // Verify length: 204 bytes (NOT 212 - no value field in Call)
    // 32 (salt) + 8 (deadline) + 32 (portal) + 8 (native_amount) + 4 (tokens.length)
    // + 32 (token) + 8 (amount) + 4 (calls.length) + 32 (target) + 4 (data.length) + 40 (data)
    expect(encoded.length).to.equal(204, 'Route should be 204 bytes without Call.value field');

    console.log('Borsh encoded length:', encoded.length);
    console.log('Borsh encoded hex:', Buffer.from(encoded).toString('hex'));
  });

  it('should successfully deserialize Solidity-encoded route bytes', () => {
    // This is the actual route bytes from running:
    // forge test --match-test test_integration_fullDepositFlow -vvvv
    //
    // Route bytes from IntentPublished event (204 bytes):
    const solidityRouteHex = 'f9c7093590b287d930b6591a4a12b39455ee7b73c55ae9532fc4e97301103009813a090000000000000000000000000000000000000000000000000000000000000000000000def0000000000000000001000000000000000000000000000000000000000000000000000000000000000000567800e40b540200000001000000000000000000000000000000000000000000000000000000000000000000567828000000000000000000000000000000000000000000000000000000000000000000111100e40b5402000000';

    const solidityRouteBytes = Buffer.from(solidityRouteHex, 'hex');

    // Verify it's 204 bytes
    expect(solidityRouteBytes.length).to.equal(204);

    // Deserialize with borsh
    const decoded = deserialize(schema, Route, solidityRouteBytes);

    // Verify structure
    expect(decoded).to.be.an('object');
    expect(decoded.salt).to.be.instanceOf(Uint8Array);
    expect(decoded.salt.length).to.equal(32);
    expect(decoded.portal).to.be.instanceOf(Uint8Array);
    expect(decoded.portal.length).to.equal(32);
    expect(decoded.tokens.length).to.equal(1);
    expect(decoded.calls.length).to.equal(1);
    expect(decoded.calls[0].data.length).to.equal(40);

    console.log('Successfully deserialized Solidity route bytes!');
    console.log('Decoded deadline:', decoded.deadline.toString());
    console.log('Decoded native_amount:', decoded.nativeAmount.toString());
    console.log('Decoded tokens.length:', decoded.tokens.length);
    console.log('Decoded calls.length:', decoded.calls.length);
    console.log('Decoded calls[0].data.length:', decoded.calls[0].data.length);
  });

  it('should round-trip encode and decode successfully', () => {
    // Create a route
    const salt = new Uint8Array(32);
    crypto.getRandomValues(salt);

    const deadline = BigInt(Math.floor(Date.now() / 1000)) + BigInt(604800);
    const portal = new Uint8Array(32).fill(0xAB);
    const token = new Uint8Array(32).fill(0xCD);
    const destination = new Uint8Array(32).fill(0xEF);
    const amount = BigInt(1_000_000);

    // Create transfer data
    const transferData = new Uint8Array(40);
    transferData.set(destination, 0);
    const amountBytes = new Uint8Array(8);
    for (let i = 0; i < 8; i++) {
      amountBytes[i] = Number((amount >> BigInt(i * 8)) & BigInt(0xFF));
    }
    transferData.set(amountBytes, 32);

    const originalRoute = new Route({
      salt: salt,
      deadline: deadline,
      portal: portal,
      nativeAmount: BigInt(0),
      tokens: [new TokenAmount({ token: token, amount: amount })],
      calls: [new Call({ target: token, data: transferData })]
    });

    // Encode
    const encoded = Buffer.from(serialize(schema, originalRoute));

    // Decode
    const decoded = deserialize(schema, Route, encoded);

    // Verify round-trip
    expect(decoded.deadline).to.equal(originalRoute.deadline);
    expect(decoded.nativeAmount).to.equal(originalRoute.nativeAmount);
    expect(decoded.tokens.length).to.equal(1);
    expect(decoded.tokens[0].amount).to.equal(amount);
    expect(decoded.calls.length).to.equal(1);
    expect(decoded.calls[0].data.length).to.equal(40);

    // Re-encode to verify byte-for-byte match
    const reencoded = Buffer.from(serialize(schema, decoded));
    expect(Buffer.from(reencoded).toString('hex')).to.equal(Buffer.from(encoded).toString('hex'));

    console.log('Round-trip successful!');
  });

  it('should verify Call struct has no value field', () => {
    // This test ensures the Call struct matches Solana's expectation
    const target = new Uint8Array(32).fill(1);
    const data = new Uint8Array(40).fill(2);

    const call = new Call({ target, data });
    const encoded = Buffer.from(serialize(schema, call));

    // Expected: 32 (target) + 4 (data.length) + 40 (data) = 76 bytes
    // If it was 84 bytes, there would be an extra 8-byte value field
    expect(encoded.length).to.equal(76, 'Call should be 76 bytes (no value field)');

    console.log('Call encoding verified: no value field present');
  });
});
