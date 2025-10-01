const { ethers } = require('ethers')

const types = {
  Person: [
    { name: 'name', type: 'string' },
    { name: 'wallet', type: 'address' },
  ],
  Mail: [
    { name: 'from', type: 'Person' },
    { name: 'to', type: 'Person' },
    { name: 'contents', type: 'string' },
    { name: 'tags', type: 'string[]' },
  ],
}

const mail = {
  from: {
    name: 'Sammy',
    wallet: '0x2020ae689ED3e017450280CEA110d0ef6E640Da4',
  },
  to: {
    name: 'Aria',
    wallet: '0x90779545ffBeF2e2A2e897b3db7b1d36c05C9e70',
  },
  contents: 'Hello, Aria!',
  tags: ['tag1', 'tag2'],
}

const personTypes = { Person: types.Person }

console.log(`From Person:
  StructHash: ${ethers.TypedDataEncoder.hashStruct('Person', personTypes, mail.from)}\n`)

console.log(`To Person:
  StructHash: ${ethers.TypedDataEncoder.hashStruct('Person', personTypes, mail.to)}\n`)

console.log(`Mail:
  StructHash: ${ethers.TypedDataEncoder.hashStruct('Mail', types, mail)}\n`)

const abiCoder = ethers.AbiCoder.defaultAbiCoder()

const personFromEncoded = abiCoder.encode(
  ['tuple(string name, address wallet)'],
  [[mail.from.name, mail.from.wallet]],
)
console.log(`From Person ABI Encoded:\n  ${personFromEncoded}\n`)

const personToEncoded = abiCoder.encode(
  ['tuple(string name, address wallet)'],
  [[mail.to.name, mail.to.wallet]],
)
console.log(`To Person ABI Encoded:\n  ${personToEncoded}\n`)

const mailEncoded = abiCoder.encode(
  [
    'tuple(tuple(string name, address wallet) from, tuple(string name, address wallet) to, string contents, string[] tags)',
  ],
  [
    [
      [mail.from.name, mail.from.wallet],
      [mail.to.name, mail.to.wallet],
      mail.contents,
      mail.tags,
    ],
  ],
)
console.log(`Mail ABI Encoded:\n  ${mailEncoded}\n`)
