import {
  createPublicClient,
  http,
  Hex,
  Address,
  hexToBytes,
  bytesToHex,
} from 'viem'
import { randomBytes } from 'crypto'
import { optimism } from 'viem/chains'

// Use a mock init code for the Inbox since functions revert if its empty even though its not needed for the address
export const MOCK_INIT_CODE =
  '0x608080604052346015576110cb908161001b8239f35b600080fdfe6080604052600436101561001b575b361561001957600080fd5b005b60003560e01c8063115f9a97146104475780632aa91bfd1461041357806337e312dc146103a257806354fd4d501461035d5780637b93f2181461033a57806382e2c43f146100d25763af9d22cf0361000e5760a03660031901126100cd576004356001600160401b0381116100cd576100bd61009e6100c9923690600401610672565b6100a6610549565b906100af61055f565b916064359160243590610b5e565b6040519182918261081c565b0390f35b600080fd5b60603660031901126100cd576004356024356001600160401b0381116100cd5761010090369060040161087c565b90916044356001600160401b0381116100cd5761012190369060040161087c565b9190928401936020818603126100cd578035906001600160401b0382116100cd5701936040858203126100cd576040519461015b866104f6565b80356001600160401b0381116100cd5782610177918301610672565b86526020810135906001600160401b0382116100cd57019060a0828203126100cd576040519160a083018381106001600160401b03821117610324576040526101bf81610575565b83526101cd60208201610575565b60208401526040830191604082013583526060820135606085015260808201356001600160401b0381116100cd5761020592016105eb565b608083015260208601918252514211610313577f0555709e59fb225fcf12cc582a9e5f7fd8eea54c91f3dc500ab9d8c37c50777060408051848152336020820152a1516040516102b2816102a4608060208301956020875260018060a01b03815116604085015260018060a01b036020820151166060850152604081015182850152606081015160a0850152015160a060c084015260e0830190610acd565b03601f198101835282610511565b519020918301936060848603126100cd576102cc84610575565b926102d960208601610575565b946040810135966001600160401b0388116100cd57610019976102fc92016105a4565b915191946001600160a01b03908116941691610a82565b6302857b7560e01b60005260046000fd5b634e487b7160e01b600052604160045260246000fd5b346100cd5760003660031901126100cd576040516308eacdfb60e21b8152602090f35b346100cd5760003660031901126100cd576100c960408051906103808183610511565b600382526219171b60e91b6020830152519182916020835260208301906107db565b60c03660031901126100cd576004356001600160401b0381116100cd576103cd903690600401610672565b6103d5610549565b6103dd61055f565b9060a435916001600160401b0383116100cd576100c9936104056100bd9436906004016105a4565b926064359160243590610a82565b346100cd5760203660031901126100cd576004356000526000602052602060018060a01b0360406000205416604051908152f35b60803660031901126100cd576024356001600160401b0381116100cd57366023820112156100cd5780600401359061047e82610532565b9161048c6040519384610511565b8083526024602084019160051b830101913683116100cd57602401905b8282106104e657836104b9610549565b90606435916001600160401b0383116100cd576104dd6100199336906004016105a4565b916004356108d3565b81358152602091820191016104a9565b604081019081106001600160401b0382111761032457604052565b90601f801991011681019081106001600160401b0382111761032457604052565b6001600160401b0381116103245760051b60200190565b604435906001600160a01b03821682036100cd57565b608435906001600160a01b03821682036100cd57565b35906001600160a01b03821682036100cd57565b6001600160401b03811161032457601f01601f191660200190565b81601f820112156100cd578035906105bb82610589565b926105c96040519485610511565b828452602083830101116100cd57816000926020809301838601378301015290565b81601f820112156100cd5780359061060282610532565b926106106040519485610511565b82845260208085019360061b830101918183116100cd57602001925b82841061063a575050505090565b6040848303126100cd5760206040918251610654816104f6565b61065d87610575565b8152828701358382015281520193019261062c565b919060c0838203126100cd5760405160c081018181106001600160401b038211176103245760405280938035825260208101356020830152604081013560408301526106c060608201610575565b606083015260808101356001600160401b0381116100cd57836106e49183016105eb565b608083015260a0810135906001600160401b0382116100cd570182601f820112156100cd5780359061071582610532565b936107236040519586610511565b82855260208086019360051b830101918183116100cd5760208101935b83851061075257505050505060a00152565b84356001600160401b0381116100cd5782016060818503601f1901126100cd5760405191606083018381106001600160401b038211176103245760405261079b60208301610575565b83526040820135926001600160401b0384116100cd576060836107c58860208098819801016105a4565b8584015201356040820152815201940193610740565b919082519283825260005b848110610807575050826000602080949584010152601f8019910116010190565b806020809284010151828286010152016107e6565b602081016020825282518091526040820191602060408360051b8301019401926000915b83831061084f57505050505090565b909192939460208061086d600193603f1986820301875289516107db565b97019301930191939290610840565b9181601f840112156100cd578235916001600160401b0383116100cd57602083818601950101116100cd57565b80518210156108bd5760209160051b010190565b634e487b7160e01b600052603260045260246000fd5b60009390926001600160a01b031691908215610a7b578151906108f582610532565b926109036040519485610511565b82845261090f83610532565b602085019390601f1901368537875b818110610a235750504793853b15610a1f579593918795939160405197889663321eb72360e21b885260a48801903360048a0152602489015260a060448901528251809152602060c48901930190895b818110610a03575050506020906003198884030160648901525191828152019290875b8181106109de575050506109b485939284926003198483030160848501526107db565b03925af180156109d3576109c6575050565b816109d091610511565b50565b6040513d84823e3d90fd5b82516001600160a01b031685528a985089975060209485019490920191600101610991565b825185528c9a508b99506020948501949092019160010161096e565b8780fd5b610a2d81846108a9565b518952602089905260408920546001600160a01b03168015610a5e5790600191610a5782896108a9565b520161091e565b60248a610a6b84876108a9565b51636d5ba68f60e11b8252600452fd5b5050505050565b949293848193610a929388610b5e565b936040805191610aa28284610511565b600183526020830191601f19013683378251156108bd57610aca9582602093505201516108d3565b90565b906020808351928381520192019060005b818110610aeb5750505090565b825180516001600160a01b031685526020908101518186015260409094019390920191600101610ade565b908160209103126100cd575180151581036100cd5790565b3d15610b59573d90610b3f82610589565b91610b4d6040519384610511565b82523d6000602084013e565b606090565b9390919260408501805146810361102057506040519460208601946020865287516040880152602088019283516060890152516080880152606088019560018060a01b0387511660a0890152608089019760a0610bc78a5160c080850152610100840190610acd565b9a0199818b51603f198284030160e0830152805180845260208401936020808360051b8301019301946000915b838310610fcb5750505050610c12925003601f198101835282610511565b519020906040519060208201928352604082015260408152610c35606082610511565b51902094516001600160a01b0316308103610fb75750828503610fa2576000858152602081905260409020546001600160a01b0316610f8d576001600160a01b0316938415610f7c577f4a817ec64beb8020b3e400f30f3b458110d5765d7a9d1ace4e68754ed2d082de91602091600052600082526040600020866bffffffffffffffffffffffff60a01b825416179055519360405195865260018060a01b031694a48051519060005b828110610ec95750505080515191610cf683610532565b92610d046040519485610511565b808452610d13601f1991610532565b0160005b818110610eb857505060005b82518051821015610eb15781610d38916108a9565b5180516001600160a01b0316803b610e2a5750602081015151610e09575b60018060a01b03815116604082019060008083516020860193845191602083519301915af192610d84610b2e565b9315610dad5750505090600191610d9b82876108a9565b52610da681866108a9565b5001610d23565b5190519151604051630978ad9160e11b81526001600160a01b0390921660048301526080602483015290918291610e05918590610dee9060848601906107db565b9160448501526003198483030160648501526107db565b0390fd5b51632db5928960e01b60009081526001600160a01b03909116600452602490fd5b6040516301ffc9a760e01b81526308eacdfb60e21b600482015290602090829060249082905afa60009181610e81575b50610e66575b50610d56565b610e705738610e60565b639cc814c560e01b60005260046000fd5b610ea391925060203d8111610eaa575b610e9b8183610511565b810190610b16565b9038610e5a565b503d610e91565b5090915050565b806060602080938801015201610d17565b610ed48183516108a9565b51610f31600080602060018060a01b0385511694015160405160208101916323b872dd60e01b8352336024830152306044830152606482015260648152610f1c608482610511565b519082865af1610f2a610b2e565b9083611034565b8051908115159182610f61575b5050610f4d5750600101610cdf565b635274afe760e01b60005260045260246000fd5b610f749250602080918301019101610b16565b153880610f3e565b6334d9914d60e11b60005260046000fd5b8463373d207960e01b60005260045260246000fd5b826344d659bf60e01b60005260045260246000fd5b631c26f26d60e01b60005260045260246000fd5b919360019193955060208091601f19858203018652885190848060a01b0382511681526040806110088585015160608786015260608501906107db565b93015191015297019301930190928694929593610bf4565b635ea03eed60e11b60005260045260246000fd5b9061105a575080511561104957805190602001fd5b630a12f52160e11b60005260046000fd5b8151158061108c575b61106b575090565b639996b31560e01b60009081526001600160a01b0391909116600452602490fd5b50803b1561106356fea26469706673582212204587aa730783db4da6c215b7b20d16d8b27f75baa873e7caa27c7b1aa2b5eff464736f6c634300081b0033' as Hex // Placeholder for actual bytecode
// CreateX contract address on Optimism
const CREATEX_ADDRESS = '0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed'

export async function createXCreate2Address(
  deployerAddress: Address,
  salt: Hex,
  bytecode: Hex,
): Promise<`0x${string}`> {
  // Create a public client for Optimism
  const client = createPublicClient({
    chain: optimism,
    transport: http(),
  })

  return (
    await client.simulateContract({
      address: CREATEX_ADDRESS,
      abi: CreateXAbi,
      functionName: 'deployCreate2',
      args: [salt, bytecode],
      account: deployerAddress,
    })
  ).result
}

export async function createXCreate3Address(
  deployerAddress: Address,
  salt: Hex,
  bytecode: Hex = MOCK_INIT_CODE,
) {
  // Create a public client for Optimism
  const client = createPublicClient({
    chain: optimism,
    transport: http(),
  })
  return (
    await client.simulateContract({
      address: CREATEX_ADDRESS,
      abi: CreateXAbi,
      functionName: 'deployCreate3',
      args: [salt, bytecode],
      account: deployerAddress,
    })
  ).result
}

/**
 * Creates a salt for CreateX deployments with specific structure:
 * - First 20 bytes: deployer address
 * - Byte 21: protection flag (0 or 1)
 * - Last 11 bytes: random data
 *
 * @param deployerAddress - The address that will deploy the contract (20 bytes)
 * @param protectionFlag - 0 for no protection, 1 for protection (1 byte)
 * @param randomSeed - Optional random seed, if not provided uses crypto.randomBytes
 * @returns 32-byte salt as hex string
 */
export function createCreateXSalt(
  deployerAddress: Address,
  protectionFlag: 0 | 1, // 0 is no replay protection, 1 is with replay protection for a chain id
  randomSeed?: Uint8Array,
): Hex {
  // Validate inputs
  if (protectionFlag !== 0 && protectionFlag !== 1) {
    throw new Error('Protection flag must be 0 or 1')
  }

  // Convert address to bytes (remove 0x prefix and convert to bytes)
  const addressBytes = hexToBytes(deployerAddress as Hex)
  if (addressBytes.length !== 20) {
    throw new Error('Invalid address: must be 20 bytes')
  }

  // Create the protection flag byte
  const protectionByte = new Uint8Array([protectionFlag])

  // Generate or use provided random bytes (11 bytes)
  const randomData = randomSeed?.slice(0, 11) || randomBytes(11)
  if (randomData.length !== 11) {
    if (randomSeed) {
      throw new Error('Random seed must be at least 11 bytes')
    }
  }

  // Combine all parts: 20 bytes address + 1 byte flag + 11 bytes random = 32 bytes total
  const saltBytes = new Uint8Array(32)
  saltBytes.set(addressBytes, 0) // Bytes 0-19: deployer address
  saltBytes.set(protectionByte, 20) // Byte 20: protection flag
  saltBytes.set(randomData, 21) // Bytes 21-31: random data

  return bytesToHex(saltBytes) as Hex
}

/**
 * Parse a CreateX salt to extract its components
 * @param salt - The 32-byte salt to parse
 * @returns Object with deployer address, protection flag, and random data
 */
export function parseCreateXSalt(salt: Hex) {
  const saltBytes = hexToBytes(salt)
  if (saltBytes.length !== 32) {
    throw new Error('Salt must be 32 bytes')
  }

  const deployerAddress = bytesToHex(saltBytes.slice(0, 20)) as Address
  const protectionFlag = saltBytes[20] as 0 | 1
  const randomData = saltBytes.slice(21)

  return {
    deployerAddress,
    protectionFlag,
    randomData: bytesToHex(randomData) as Hex,
  }
}

/**
 * Check if a salt follows CreateX format for a specific deployer
 * @param salt - The salt to check
 * @param expectedDeployer - The expected deployer address
 * @returns True if salt is valid for the deployer
 */
export function isValidCreateXSalt(
  salt: Hex,
  expectedDeployer: Address,
): boolean {
  try {
    const parsed = parseCreateXSalt(salt)
    return (
      parsed.deployerAddress.toLowerCase() === expectedDeployer.toLowerCase()
    )
  } catch {
    return false
  }
}

export const CreateXAbi = [
  {
    inputs: [
      {
        internalType: 'address',
        name: 'emitter',
        type: 'address',
      },
    ],
    name: 'FailedContractCreation',
    type: 'error',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'emitter',
        type: 'address',
      },
      {
        internalType: 'bytes',
        name: 'revertData',
        type: 'bytes',
      },
    ],
    name: 'FailedContractInitialisation',
    type: 'error',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'emitter',
        type: 'address',
      },
      {
        internalType: 'bytes',
        name: 'revertData',
        type: 'bytes',
      },
    ],
    name: 'FailedEtherTransfer',
    type: 'error',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'emitter',
        type: 'address',
      },
    ],
    name: 'InvalidNonceValue',
    type: 'error',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'emitter',
        type: 'address',
      },
    ],
    name: 'InvalidSalt',
    type: 'error',
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
      {
        indexed: true,
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
    ],
    name: 'ContractCreation',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    name: 'ContractCreation',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
      {
        indexed: true,
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
    ],
    name: 'Create3ProxyContractCreation',
    type: 'event',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes32',
        name: 'initCodeHash',
        type: 'bytes32',
      },
    ],
    name: 'computeCreate2Address',
    outputs: [
      {
        internalType: 'address',
        name: 'computedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes32',
        name: 'initCodeHash',
        type: 'bytes32',
      },
      {
        internalType: 'address',
        name: 'deployer',
        type: 'address',
      },
    ],
    name: 'computeCreate2Address',
    outputs: [
      {
        internalType: 'address',
        name: 'computedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'pure',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'address',
        name: 'deployer',
        type: 'address',
      },
    ],
    name: 'computeCreate3Address',
    outputs: [
      {
        internalType: 'address',
        name: 'computedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'pure',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
    ],
    name: 'computeCreate3Address',
    outputs: [
      {
        internalType: 'address',
        name: 'computedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'uint256',
        name: 'nonce',
        type: 'uint256',
      },
    ],
    name: 'computeCreateAddress',
    outputs: [
      {
        internalType: 'address',
        name: 'computedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'deployer',
        type: 'address',
      },
      {
        internalType: 'uint256',
        name: 'nonce',
        type: 'uint256',
      },
    ],
    name: 'computeCreateAddress',
    outputs: [
      {
        internalType: 'address',
        name: 'computedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
    ],
    name: 'deployCreate',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
    ],
    name: 'deployCreate2',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
    ],
    name: 'deployCreate2',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
      {
        internalType: 'address',
        name: 'refundAddress',
        type: 'address',
      },
    ],
    name: 'deployCreate2AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
    ],
    name: 'deployCreate2AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
      {
        internalType: 'address',
        name: 'refundAddress',
        type: 'address',
      },
    ],
    name: 'deployCreate2AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
    ],
    name: 'deployCreate2AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'address',
        name: 'implementation',
        type: 'address',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
    ],
    name: 'deployCreate2Clone',
    outputs: [
      {
        internalType: 'address',
        name: 'proxy',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'implementation',
        type: 'address',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
    ],
    name: 'deployCreate2Clone',
    outputs: [
      {
        internalType: 'address',
        name: 'proxy',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
    ],
    name: 'deployCreate3',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
    ],
    name: 'deployCreate3',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
    ],
    name: 'deployCreate3AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
    ],
    name: 'deployCreate3AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
      {
        internalType: 'address',
        name: 'refundAddress',
        type: 'address',
      },
    ],
    name: 'deployCreate3AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
      {
        internalType: 'address',
        name: 'refundAddress',
        type: 'address',
      },
    ],
    name: 'deployCreate3AndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
    ],
    name: 'deployCreateAndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
      {
        components: [
          {
            internalType: 'uint256',
            name: 'constructorAmount',
            type: 'uint256',
          },
          {
            internalType: 'uint256',
            name: 'initCallAmount',
            type: 'uint256',
          },
        ],
        internalType: 'struct CreateX.Values',
        name: 'values',
        type: 'tuple',
      },
      {
        internalType: 'address',
        name: 'refundAddress',
        type: 'address',
      },
    ],
    name: 'deployCreateAndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'newContract',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'address',
        name: 'implementation',
        type: 'address',
      },
      {
        internalType: 'bytes',
        name: 'data',
        type: 'bytes',
      },
    ],
    name: 'deployCreateClone',
    outputs: [
      {
        internalType: 'address',
        name: 'proxy',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
] as const
