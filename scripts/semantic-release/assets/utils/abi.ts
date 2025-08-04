export const IntentSourceAbi = [
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
      "name": "FailedInnerCall",
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
      "inputs": [],
      "name": "InvalidRefundToken",
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
      "name": "WrongSourceChain",
      "type": "error"
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
          "internalType": "bytes32",
          "name": "salt",
          "type": "bytes32"
        },
        {
          "indexed": false,
          "internalType": "uint256",
          "name": "source",
          "type": "uint256"
        },
        {
          "indexed": false,
          "internalType": "uint256",
          "name": "destination",
          "type": "uint256"
        },
        {
          "indexed": false,
          "internalType": "address",
          "name": "inbox",
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
          "indexed": false,
          "internalType": "struct TokenAmount[]",
          "name": "routeTokens",
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
          "indexed": false,
          "internalType": "struct Call[]",
          "name": "calls",
          "type": "tuple[]"
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
          "internalType": "uint256",
          "name": "deadline",
          "type": "uint256"
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
        }
      ],
      "name": "IntentCreated",
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
        },
        {
          "indexed": false,
          "internalType": "address",
          "name": "funder",
          "type": "address"
        }
      ],
      "name": "IntentPartiallyFunded",
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
      "name": "Refund",
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
      "name": "Withdrawal",
      "type": "event"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
          "internalType": "struct Intent[]",
          "name": "_intents",
          "type": "tuple[]"
        }
      ],
      "name": "batchWithdraw",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
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
              "name": "deadline",
              "type": "uint256"
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
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
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
              "name": "deadline",
              "type": "uint256"
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
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
        }
      ],
      "stateMutability": "payable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
        }
      ],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [
        {
          "internalType": "bytes32",
          "name": "routeHash",
          "type": "bytes32"
        },
        {
          "components": [
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
              "name": "deadline",
              "type": "uint256"
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
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
          "name": "_intent",
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
          "components": [
            {
              "components": [
                {
                  "internalType": "bytes32",
                  "name": "salt",
                  "type": "bytes32"
                },
                {
                  "internalType": "uint256",
                  "name": "source",
                  "type": "uint256"
                },
                {
                  "internalType": "uint256",
                  "name": "destination",
                  "type": "uint256"
                },
                {
                  "internalType": "address",
                  "name": "inbox",
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
                  "name": "deadline",
                  "type": "uint256"
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
          "name": "_intent",
          "type": "tuple"
        }
      ],
      "name": "withdrawRewards",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    }
  ] as const