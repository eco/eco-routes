export const PortalAbi = [
    {
      "inputs": [],
      "stateMutability": "nonpayable",
      "type": "constructor"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "target",
          "type": "address"
        }
      ],
      "name": "AddressEmptyCode",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "account",
          "type": "address"
        }
      ],
      "name": "AddressInsufficientBalance",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "ArrayLengthMismatch",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "BadSignature",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "eoa",
          "type": "address"
        }
      ],
      "name": "CallToEOA",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "CallToProver",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "CannotFundForWithNativeReward",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "ECDSAInvalidSignature",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "uint256",
          "name": "length",
          "type": "uint256"
        }
      ],
      "name": "ECDSAInvalidSignatureLength",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "s",
          "type": "bytes32"
        }
      ],
      "name": "ECDSAInvalidSignatureS",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "FailedInnerCall",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "FillDeadlinePassed",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "InsufficientNativeReward",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "InsufficientNativeRewardAmount",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "token",
          "type": "address"
        },
        {
          "internalType": "address",
          "name": "spender",
          "type": "address"
        },
        {
          "internalType": "uint256",
          "name": "amount",
          "type": "uint256"
        }
      ],
      "name": "InsufficientTokenAllowance",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "IntentAlreadyExists",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        }
      ],
      "name": "IntentAlreadyFulfilled",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "IntentAlreadyFunded",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "addr",
          "type": "address"
        },
        {
          "internalType": "bytes",
          "name": "data",
          "type": "bytes"
        },
        {
          "internalType": "uint256",
          "name": "value",
          "type": "uint256"
        },
        {
          "internalType": "bytes",
          "name": "returnData",
          "type": "bytes"
        }
      ],
      "name": "IntentCallFailed",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "IntentExpired",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "IntentNotClaimed",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "IntentNotExpired",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        }
      ],
      "name": "IntentNotFulfilled",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "expectedHash",
          "type": "bytes32"
        }
      ],
      "name": "InvalidHash",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "portal",
          "type": "address"
        }
      ],
      "name": "InvalidPortal",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "InvalidRefundToken",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "InvalidShortString",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "NativeRewardTransferFailed",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "OpenDeadlinePassed",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "OriginChainIDMismatch",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        }
      ],
      "name": "RewardsAlreadyWithdrawn",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "token",
          "type": "address"
        }
      ],
      "name": "SafeERC20FailedOperation",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "string",
          "name": "str",
          "type": "string"
        }
      ],
      "name": "StringTooLong",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "TypeSignatureMismatch",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        }
      ],
      "name": "UnauthorizedWithdrawal",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "VaultCreationFailed",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "uint256",
          "name": "chainID",
          "type": "uint256"
        }
      ],
      "name": "WrongChain",
      "type": "error"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "WrongSourceChain",
      "type": "error"
    },
    {
      "inputs": [],
      "name": "ZeroClaimant",
      "type": "error"
    },
    {
      "anonymous": false,
      "inputs": [],
      "name": "EIP712DomainChanged",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": true,
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        },
        {
          "indexed": true,
          "internalType": "bytes32",
          "name": "claimant",
          "type": "bytes32"
        }
      ],
      "name": "IntentFulfilled",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": false,
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "indexed": false,
          "internalType": "address",
          "name": "funder",
          "type": "address"
        },
        {
          "indexed": false,
          "internalType": "bool",
          "name": "complete",
          "type": "bool"
        }
      ],
      "name": "IntentFunded",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": false,
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "IntentProofChallenged",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": true,
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        },
        {
          "indexed": false,
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "indexed": true,
          "internalType": "address",
          "name": "creator",
          "type": "address"
        },
        {
          "indexed": true,
          "internalType": "address",
          "name": "prover",
          "type": "address"
        },
        {
          "indexed": false,
          "internalType": "uint64",
          "name": "rewardDeadline",
          "type": "uint64"
        },
        {
          "indexed": false,
          "internalType": "uint256",
          "name": "nativeValue",
          "type": "uint256"
        },
        {
          "components": [
            {
              "internalType": "address",
              "name": "token",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "amount",
              "type": "uint256"
            }
          ],
          "indexed": false,
          "internalType": "struct TokenAmount[]",
          "name": "rewardTokens",
          "type": "tuple[]"
        },
        {
          "indexed": false,
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        }
      ],
      "name": "IntentPublished",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": false,
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        },
        {
          "indexed": true,
          "internalType": "address",
          "name": "recipient",
          "type": "address"
        }
      ],
      "name": "IntentRefunded",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": false,
          "internalType": "bytes32",
          "name": "hash",
          "type": "bytes32"
        },
        {
          "indexed": true,
          "internalType": "address",
          "name": "recipient",
          "type": "address"
        }
      ],
      "name": "IntentWithdrawn",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": true,
          "internalType": "bytes32",
          "name": "orderId",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "address",
              "name": "user",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "originChainId",
              "type": "uint256"
            },
            {
              "internalType": "uint32",
              "name": "openDeadline",
              "type": "uint32"
            },
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderId",
              "type": "bytes32"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "maxSpent",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "minReceived",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "destination",
                  "type": "uint64"
                },
                {
                  "internalType": "bytes32",
                  "name": "destinationSettler",
                  "type": "bytes32"
                },
                {
                  "internalType": "bytes",
                  "name": "originData",
                  "type": "bytes"
                }
              ],
              "internalType": "struct FillInstruction[]",
              "name": "fillInstructions",
              "type": "tuple[]"
            }
          ],
          "indexed": false,
          "internalType": "struct ResolvedCrossChainOrder",
          "name": "resolvedOrder",
          "type": "tuple"
        }
      ],
      "name": "Open",
      "type": "event"
    },
    {
      "anonymous": false,
      "inputs": [
        {
          "indexed": false,
          "internalType": "bytes32",
          "name": "orderId",
          "type": "bytes32"
        },
        {
          "indexed": false,
          "internalType": "address",
          "name": "solver",
          "type": "address"
        }
      ],
      "name": "OrderFilled",
      "type": "event"
    },
    {
      "inputs": [],
      "name": "GASLESS_CROSSCHAIN_ORDER_TYPEHASH",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "",
          "type": "bytes32"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [],
      "name": "IPROVER_INTERFACE_ID",
      "outputs": [
        {
          "internalType": "bytes4",
          "name": "",
          "type": "bytes4"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint32",
          "name": "openDeadline",
          "type": "uint32"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "internalType": "bytes32",
              "name": "portal",
              "type": "bytes32"
            },
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "bytes",
              "name": "route",
              "type": "bytes"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct OrderData",
          "name": "orderData",
          "type": "tuple"
        }
      ],
      "name": "_resolve",
      "outputs": [
        {
          "components": [
            {
              "internalType": "address",
              "name": "user",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "originChainId",
              "type": "uint256"
            },
            {
              "internalType": "uint32",
              "name": "openDeadline",
              "type": "uint32"
            },
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderId",
              "type": "bytes32"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "maxSpent",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "minReceived",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "destination",
                  "type": "uint64"
                },
                {
                  "internalType": "bytes32",
                  "name": "destinationSettler",
                  "type": "bytes32"
                },
                {
                  "internalType": "bytes",
                  "name": "originData",
                  "type": "bytes"
                }
              ],
              "internalType": "struct FillInstruction[]",
              "name": "fillInstructions",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct ResolvedCrossChainOrder",
          "name": "",
          "type": "tuple"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64[]",
          "name": "destinations",
          "type": "uint64[]"
        },
        {
          "internalType": "bytes32[]",
          "name": "routeHashes",
          "type": "bytes32[]"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward[]",
          "name": "rewards",
          "type": "tuple[]"
        }
      ],
      "name": "batchWithdraw",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [],
      "name": "domainSeparatorV4",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "",
          "type": "bytes32"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [],
      "name": "eip712Domain",
      "outputs": [
        {
          "internalType": "bytes1",
          "name": "fields",
          "type": "bytes1"
        },
        {
          "internalType": "string",
          "name": "name",
          "type": "string"
        },
        {
          "internalType": "string",
          "name": "version",
          "type": "string"
        },
        {
          "internalType": "uint256",
          "name": "chainId",
          "type": "uint256"
        },
        {
          "internalType": "address",
          "name": "verifyingContract",
          "type": "address"
        },
        {
          "internalType": "bytes32",
          "name": "salt",
          "type": "bytes32"
        },
        {
          "internalType": "uint256[]",
          "name": "extensions",
          "type": "uint256[]"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "orderId",
          "type": "bytes32"
        },
        {
          "internalType": "bytes",
          "name": "originData",
          "type": "bytes"
        },
        {
          "internalType": "bytes",
          "name": "fillerData",
          "type": "bytes"
        }
      ],
      "name": "fill",
      "outputs": [],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "bytes32",
              "name": "salt",
              "type": "bytes32"
            },
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "portal",
              "type": "address"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "target",
                  "type": "address"
                },
                {
                  "internalType": "bytes",
                  "name": "data",
                  "type": "bytes"
                },
                {
                  "internalType": "uint256",
                  "name": "value",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Call[]",
              "name": "calls",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Route",
          "name": "route",
          "type": "tuple"
        },
        {
          "internalType": "bytes32",
          "name": "rewardHash",
          "type": "bytes32"
        },
        {
          "internalType": "bytes32",
          "name": "claimant",
          "type": "bytes32"
        }
      ],
      "name": "fulfill",
      "outputs": [
        {
          "internalType": "bytes[]",
          "name": "",
          "type": "bytes[]"
        }
      ],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "bytes32",
              "name": "salt",
              "type": "bytes32"
            },
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "portal",
              "type": "address"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "target",
                  "type": "address"
                },
                {
                  "internalType": "bytes",
                  "name": "data",
                  "type": "bytes"
                },
                {
                  "internalType": "uint256",
                  "name": "value",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Call[]",
              "name": "calls",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Route",
          "name": "route",
          "type": "tuple"
        },
        {
          "internalType": "bytes32",
          "name": "rewardHash",
          "type": "bytes32"
        },
        {
          "internalType": "bytes32",
          "name": "claimant",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "prover",
          "type": "address"
        },
        {
          "internalType": "uint64",
          "name": "source",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "data",
          "type": "bytes"
        }
      ],
      "name": "fulfillAndProve",
      "outputs": [
        {
          "internalType": "bytes[]",
          "name": "",
          "type": "bytes[]"
        }
      ],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "",
          "type": "bytes32"
        }
      ],
      "name": "fulfilled",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "",
          "type": "bytes32"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        },
        {
          "internalType": "bool",
          "name": "allowPartial",
          "type": "bool"
        }
      ],
      "name": "fund",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        },
        {
          "internalType": "address",
          "name": "funder",
          "type": "address"
        },
        {
          "internalType": "address",
          "name": "permitContract",
          "type": "address"
        },
        {
          "internalType": "bool",
          "name": "allowPartial",
          "type": "bool"
        }
      ],
      "name": "fundFor",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        }
      ],
      "name": "getIntentHash",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "internalType": "bytes32",
          "name": "rewardHash",
          "type": "bytes32"
        }
      ],
      "stateMutability": "pure",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "portal",
                  "type": "address"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "target",
                      "type": "address"
                    },
                    {
                      "internalType": "bytes",
                      "name": "data",
                      "type": "bytes"
                    },
                    {
                      "internalType": "uint256",
                      "name": "value",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct Call[]",
                  "name": "calls",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Route",
              "name": "route",
              "type": "tuple"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct Intent",
          "name": "intent",
          "type": "tuple"
        }
      ],
      "name": "getIntentHash",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "internalType": "bytes32",
          "name": "rewardHash",
          "type": "bytes32"
        }
      ],
      "stateMutability": "pure",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "getPermitContract",
      "outputs": [
        {
          "internalType": "address",
          "name": "",
          "type": "address"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "getRewardStatus",
      "outputs": [
        {
          "internalType": "enum IVaultStorage.RewardStatus",
          "name": "status",
          "type": "uint8"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "getVaultState",
      "outputs": [
        {
          "components": [
            {
              "internalType": "uint8",
              "name": "status",
              "type": "uint8"
            },
            {
              "internalType": "uint8",
              "name": "mode",
              "type": "uint8"
            },
            {
              "internalType": "uint8",
              "name": "allowPartialFunding",
              "type": "uint8"
            },
            {
              "internalType": "uint8",
              "name": "usePermit",
              "type": "uint8"
            },
            {
              "internalType": "address",
              "name": "target",
              "type": "address"
            }
          ],
          "internalType": "struct IVaultStorage.VaultState",
          "name": "",
          "type": "tuple"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        }
      ],
      "name": "intentVaultAddress",
      "outputs": [
        {
          "internalType": "address",
          "name": "",
          "type": "address"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "portal",
                  "type": "address"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "target",
                      "type": "address"
                    },
                    {
                      "internalType": "bytes",
                      "name": "data",
                      "type": "bytes"
                    },
                    {
                      "internalType": "uint256",
                      "name": "value",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct Call[]",
                  "name": "calls",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Route",
              "name": "route",
              "type": "tuple"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct Intent",
          "name": "intent",
          "type": "tuple"
        }
      ],
      "name": "intentVaultAddress",
      "outputs": [
        {
          "internalType": "address",
          "name": "",
          "type": "address"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        }
      ],
      "name": "isIntentFunded",
      "outputs": [
        {
          "internalType": "bool",
          "name": "",
          "type": "bool"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "portal",
                  "type": "address"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "target",
                      "type": "address"
                    },
                    {
                      "internalType": "bytes",
                      "name": "data",
                      "type": "bytes"
                    },
                    {
                      "internalType": "uint256",
                      "name": "value",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct Call[]",
                  "name": "calls",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Route",
              "name": "route",
              "type": "tuple"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct Intent",
          "name": "intent",
          "type": "tuple"
        }
      ],
      "name": "isIntentFunded",
      "outputs": [
        {
          "internalType": "bool",
          "name": "",
          "type": "bool"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderDataType",
              "type": "bytes32"
            },
            {
              "internalType": "bytes",
              "name": "orderData",
              "type": "bytes"
            }
          ],
          "internalType": "struct OnchainCrossChainOrder",
          "name": "order",
          "type": "tuple"
        }
      ],
      "name": "open",
      "outputs": [],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "address",
              "name": "originSettler",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "user",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nonce",
              "type": "uint256"
            },
            {
              "internalType": "uint256",
              "name": "originChainId",
              "type": "uint256"
            },
            {
              "internalType": "uint32",
              "name": "openDeadline",
              "type": "uint32"
            },
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderDataType",
              "type": "bytes32"
            },
            {
              "internalType": "bytes",
              "name": "orderData",
              "type": "bytes"
            }
          ],
          "internalType": "struct GaslessCrossChainOrder",
          "name": "order",
          "type": "tuple"
        },
        {
          "internalType": "bytes",
          "name": "signature",
          "type": "bytes"
        },
        {
          "internalType": "bytes",
          "name": "",
          "type": "bytes"
        }
      ],
      "name": "openFor",
      "outputs": [],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint256",
          "name": "source",
          "type": "uint256"
        },
        {
          "internalType": "address",
          "name": "prover",
          "type": "address"
        },
        {
          "internalType": "bytes32[]",
          "name": "intentHashes",
          "type": "bytes32[]"
        },
        {
          "internalType": "bytes",
          "name": "data",
          "type": "bytes"
        }
      ],
      "name": "prove",
      "outputs": [],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        }
      ],
      "name": "publish",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "vault",
          "type": "address"
        }
      ],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "portal",
                  "type": "address"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "target",
                      "type": "address"
                    },
                    {
                      "internalType": "bytes",
                      "name": "data",
                      "type": "bytes"
                    },
                    {
                      "internalType": "uint256",
                      "name": "value",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct Call[]",
                  "name": "calls",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Route",
              "name": "route",
              "type": "tuple"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct Intent",
          "name": "intent",
          "type": "tuple"
        }
      ],
      "name": "publish",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "vault",
          "type": "address"
        }
      ],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "portal",
                  "type": "address"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "target",
                      "type": "address"
                    },
                    {
                      "internalType": "bytes",
                      "name": "data",
                      "type": "bytes"
                    },
                    {
                      "internalType": "uint256",
                      "name": "value",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct Call[]",
                  "name": "calls",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Route",
              "name": "route",
              "type": "tuple"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct Intent",
          "name": "intent",
          "type": "tuple"
        },
        {
          "internalType": "bool",
          "name": "allowPartial",
          "type": "bool"
        }
      ],
      "name": "publishAndFund",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "vault",
          "type": "address"
        }
      ],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        },
        {
          "internalType": "bool",
          "name": "allowPartial",
          "type": "bool"
        }
      ],
      "name": "publishAndFund",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "vault",
          "type": "address"
        }
      ],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes",
          "name": "route",
          "type": "bytes"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        },
        {
          "internalType": "address",
          "name": "funder",
          "type": "address"
        },
        {
          "internalType": "address",
          "name": "permitContract",
          "type": "address"
        },
        {
          "internalType": "bool",
          "name": "allowPartial",
          "type": "bool"
        }
      ],
      "name": "publishAndFundFor",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "vault",
          "type": "address"
        }
      ],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "destination",
              "type": "uint64"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "portal",
                  "type": "address"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "target",
                      "type": "address"
                    },
                    {
                      "internalType": "bytes",
                      "name": "data",
                      "type": "bytes"
                    },
                    {
                      "internalType": "uint256",
                      "name": "value",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct Call[]",
                  "name": "calls",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Route",
              "name": "route",
              "type": "tuple"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "deadline",
                  "type": "uint64"
                },
                {
                  "internalType": "address",
                  "name": "creator",
                  "type": "address"
                },
                {
                  "internalType": "address",
                  "name": "prover",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "nativeValue",
                  "type": "uint256"
                },
                {
                  "components": [
                    {
                      "internalType": "address",
                      "name": "token",
                      "type": "address"
                    },
                    {
                      "internalType": "uint256",
                      "name": "amount",
                      "type": "uint256"
                    }
                  ],
                  "internalType": "struct TokenAmount[]",
                  "name": "tokens",
                  "type": "tuple[]"
                }
              ],
              "internalType": "struct Reward",
              "name": "reward",
              "type": "tuple"
            }
          ],
          "internalType": "struct Intent",
          "name": "intent",
          "type": "tuple"
        },
        {
          "internalType": "address",
          "name": "funder",
          "type": "address"
        },
        {
          "internalType": "address",
          "name": "permitContract",
          "type": "address"
        },
        {
          "internalType": "bool",
          "name": "allowPartial",
          "type": "bool"
        }
      ],
      "name": "publishAndFundFor",
      "outputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        },
        {
          "internalType": "address",
          "name": "vault",
          "type": "address"
        }
      ],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        },
        {
          "internalType": "address",
          "name": "token",
          "type": "address"
        }
      ],
      "name": "recoverToken",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        }
      ],
      "name": "refund",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderDataType",
              "type": "bytes32"
            },
            {
              "internalType": "bytes",
              "name": "orderData",
              "type": "bytes"
            }
          ],
          "internalType": "struct OnchainCrossChainOrder",
          "name": "order",
          "type": "tuple"
        }
      ],
      "name": "resolve",
      "outputs": [
        {
          "components": [
            {
              "internalType": "address",
              "name": "user",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "originChainId",
              "type": "uint256"
            },
            {
              "internalType": "uint32",
              "name": "openDeadline",
              "type": "uint32"
            },
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderId",
              "type": "bytes32"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "maxSpent",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "minReceived",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "destination",
                  "type": "uint64"
                },
                {
                  "internalType": "bytes32",
                  "name": "destinationSettler",
                  "type": "bytes32"
                },
                {
                  "internalType": "bytes",
                  "name": "originData",
                  "type": "bytes"
                }
              ],
              "internalType": "struct FillInstruction[]",
              "name": "fillInstructions",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct ResolvedCrossChainOrder",
          "name": "",
          "type": "tuple"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "internalType": "address",
              "name": "originSettler",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "user",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nonce",
              "type": "uint256"
            },
            {
              "internalType": "uint256",
              "name": "originChainId",
              "type": "uint256"
            },
            {
              "internalType": "uint32",
              "name": "openDeadline",
              "type": "uint32"
            },
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderDataType",
              "type": "bytes32"
            },
            {
              "internalType": "bytes",
              "name": "orderData",
              "type": "bytes"
            }
          ],
          "internalType": "struct GaslessCrossChainOrder",
          "name": "order",
          "type": "tuple"
        },
        {
          "internalType": "bytes",
          "name": "",
          "type": "bytes"
        }
      ],
      "name": "resolveFor",
      "outputs": [
        {
          "components": [
            {
              "internalType": "address",
              "name": "user",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "originChainId",
              "type": "uint256"
            },
            {
              "internalType": "uint32",
              "name": "openDeadline",
              "type": "uint32"
            },
            {
              "internalType": "uint32",
              "name": "fillDeadline",
              "type": "uint32"
            },
            {
              "internalType": "bytes32",
              "name": "orderId",
              "type": "bytes32"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "maxSpent",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "token",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                },
                {
                  "internalType": "bytes32",
                  "name": "recipient",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "chainId",
                  "type": "uint256"
                }
              ],
              "internalType": "struct Output[]",
              "name": "minReceived",
              "type": "tuple[]"
            },
            {
              "components": [
                {
                  "internalType": "uint64",
                  "name": "destination",
                  "type": "uint64"
                },
                {
                  "internalType": "bytes32",
                  "name": "destinationSettler",
                  "type": "bytes32"
                },
                {
                  "internalType": "bytes",
                  "name": "originData",
                  "type": "bytes"
                }
              ],
              "internalType": "struct FillInstruction[]",
              "name": "fillInstructions",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct ResolvedCrossChainOrder",
          "name": "",
          "type": "tuple"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "intentHash",
          "type": "bytes32"
        }
      ],
      "name": "vaults",
      "outputs": [
        {
          "components": [
            {
              "internalType": "uint8",
              "name": "status",
              "type": "uint8"
            },
            {
              "internalType": "uint8",
              "name": "mode",
              "type": "uint8"
            },
            {
              "internalType": "uint8",
              "name": "allowPartialFunding",
              "type": "uint8"
            },
            {
              "internalType": "uint8",
              "name": "usePermit",
              "type": "uint8"
            },
            {
              "internalType": "address",
              "name": "target",
              "type": "address"
            }
          ],
          "internalType": "struct IVaultStorage.VaultState",
          "name": "state",
          "type": "tuple"
        },
        {
          "internalType": "address",
          "name": "permitContract",
          "type": "address"
        }
      ],
      "stateMutability": "view",
      "type": "function"
    },
    {
      "inputs": [],
      "name": "version",
      "outputs": [
        {
          "internalType": "string",
          "name": "",
          "type": "string"
        }
      ],
      "stateMutability": "pure",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "uint64",
          "name": "destination",
          "type": "uint64"
        },
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
            {
              "internalType": "uint64",
              "name": "deadline",
              "type": "uint64"
            },
            {
              "internalType": "address",
              "name": "creator",
              "type": "address"
            },
            {
              "internalType": "address",
              "name": "prover",
              "type": "address"
            },
            {
              "internalType": "uint256",
              "name": "nativeValue",
              "type": "uint256"
            },
            {
              "components": [
                {
                  "internalType": "address",
                  "name": "token",
                  "type": "address"
                },
                {
                  "internalType": "uint256",
                  "name": "amount",
                  "type": "uint256"
                }
              ],
              "internalType": "struct TokenAmount[]",
              "name": "tokens",
              "type": "tuple[]"
            }
          ],
          "internalType": "struct Reward",
          "name": "reward",
          "type": "tuple"
        }
      ],
      "name": "withdraw",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "stateMutability": "payable",
      "type": "receive"
    }
  ] as const'