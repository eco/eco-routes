import { encodeRlp, stripZerosLeft, toBeHex, keccak256 } from 'ethers'

export namespace utils {
  export async function getRLPEncodedBlock(block) {
    console.log('In getRLPEncodedBlock')

    const rlpEncodedBlockData = encodeRlp([
      block.parentHash,
      block.sha3Uncles,
      block.miner,
      block.stateRoot,
      block.transactionsRoot,
      block.receiptsRoot,
      block.logsBloom,
      stripZerosLeft(toBeHex(block.difficulty)), // Add stripzeros left here
      toBeHex(block.number),
      toBeHex(block.gasLimit),
      toBeHex(block.gasUsed),
      block.timestamp,
      block.extraData,
      block.mixHash,
      block.nonce,
      toBeHex(block.baseFeePerGas),
      block.withdrawalsRoot,
      stripZerosLeft(toBeHex(block.blobGasUsed)),
      stripZerosLeft(toBeHex(block.excessBlobGas)),
      block.parentBeaconBlockRoot,
    ])
    // check the hash is valid
    const hash = keccak256(rlpEncodedBlockData)
    if (hash !== block.hash) {
      console.log('Hash of RLP Encoded Block Data: ', hash)
      console.log('Block Hash: ', block.hash)
      console.log('Hashes do not match')
      throw Error('Hashes do not match')
    }
    // console.log('About to return RLP Encoded Block Data: ', rlpEncodedBlockData)
    return rlpEncodedBlockData
  }
  export async function getRLPEncodedBlockHardhat(block) {
    console.log('In getRLPEncodedBlock')

    const rlpEncodedBlockData = encodeRlp([
      block.parentHash,
      //   block.sha3Uncles,
      block.miner,
      //   block.stateRoot,
      //   block.transactionsRoot,
      //   block.receiptsRoot,
      //   block.logsBloom,
      stripZerosLeft(toBeHex(block.difficulty)), // Add stripzeros left here
      toBeHex(block.number),
      toBeHex(block.gasLimit),
      toBeHex(block.gasUsed),
      toBeHex(block.timestamp),
      //   toBeHex(block.extraData),
      //   block.mixHash,
      //   block.nonce,
      //   toBeHex(block.baseFeePerGas),
      //   block.withdrawalsRoot,
      //   stripZerosLeft(toBeHex(block.blobGasUsed)),
      //   stripZerosLeft(toBeHex(block.excessBlobGas)),
      //   block.parentBeaconBlockRoot,
    ])
    // console.log('About to return RLP Encoded Block Data: ', rlpEncodedBlockData)
    return rlpEncodedBlockData
  }
}
