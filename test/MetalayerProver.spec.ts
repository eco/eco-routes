import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type {
  MetalayerProver,
  Inbox,
  TestERC20,
  TestRouter,
} from "../typechain-types";
import { encodeTransfer } from "../utils/encode";

describe("MetalayerProver Test", (): void => {
  let inbox: Inbox;
  let router: TestRouter;
  let metalayerProver: MetalayerProver;
  let token: TestERC20;
  let owner: SignerWithAddress;
  let solver: SignerWithAddress;
  let claimant: SignerWithAddress;
  const amount: number = 1234567890;
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();

  async function deployMetalayerProverFixture(): Promise<{
    inbox: Inbox;
    token: TestERC20;
    owner: SignerWithAddress;
    solver: SignerWithAddress;
    claimant: SignerWithAddress;
  }> {
    const [owner, solver, claimant] = await ethers.getSigners();
    router = await (await ethers.getContractFactory("TestRouter")).deploy(
      await owner.getAddress(),
    );

    const inbox = await (await ethers.getContractFactory("Inbox")).deploy(
      owner.address,
      true,
      [],
    );

    const token = await (await ethers.getContractFactory("TestERC20")).deploy(
      "token",
      "tkn",
    );

    return {
      inbox,
      token,
      owner,
      solver,
      claimant,
    };
  }

  beforeEach(async (): Promise<void> => {
    ({ inbox, token, owner, solver, claimant } = await loadFixture(
      deployMetalayerProverFixture,
    ));
  });

  describe("on prover implements interface", () => {
    it("should return the correct proof type", async () => {
      metalayerProver = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await router.getAddress(), await inbox.getAddress());
      expect(await metalayerProver.getProofType()).to.equal(2); // ProofType.Metalayer
    });
  });

  describe("invalid", async () => {
    beforeEach(async () => {
      metalayerProver = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await router.getAddress(), await inbox.getAddress());
    });

    it("should revert when msg.sender is not the router", async () => {
      await expect(
        metalayerProver
          .connect(solver)
          .handle(12345, solver.address, ethers.toUtf8Bytes(""), [], []),
      ).to.be.revertedWithCustomError(metalayerProver, "UnauthorizedHandle");
    });

    it("should revert when sender field is not the inbox", async () => {
      const prover = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await owner.getAddress(), await inbox.getAddress());
      await expect(
        prover
          .connect(owner)
          .handle(12345, solver.address, ethers.toUtf8Bytes(""), [], []),
      ).to.be.revertedWithCustomError(prover, "UnauthorizedDispatch");
    });
  });

  describe("valid instant", async () => {
    it("should handle the message if it comes from the correct inbox and router", async () => {
      const prover = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await owner.getAddress(), await inbox.getAddress());
      await token.mint(solver.address, amount);
      const intentHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
      const claimantAddress = await claimant.getAddress();
      const msgBody = abiCoder.encode(
        ["bytes32[]", "address[]"],
        [[intentHash], [claimantAddress]],
      );

      expect(await prover.provenIntents(intentHash)).to.eq(ethers.ZeroAddress);

      await expect(
        prover
          .connect(owner)
          .handle(12345, await inbox.getAddress(), msgBody, [], []),
      )
        .to.emit(prover, "IntentProven")
        .withArgs(intentHash, claimantAddress);

      expect(await prover.provenIntents(intentHash)).to.eq(claimantAddress);
    });

    it("works end to end", async () => {
      const prover = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await router.getAddress(), await inbox.getAddress());
      await inbox.connect(owner).setRouter(await router.getAddress());
      await token.mint(solver.address, amount);
      const sourceChainID = 12345;
      const calldata = await encodeTransfer(
        await claimant.getAddress(),
        amount,
      );
      const timeStamp = Math.floor(Date.now() / 1000) + 1000;
      const nonce = ethers.encodeBytes32String("0x987");
      const intermediateHash = ethers.keccak256(
        abiCoder.encode(
          ["uint256", "uint256", "address[]", "bytes[]", "uint256", "bytes32"],
          [
            sourceChainID,
            (await owner.provider.getNetwork()).chainId,
            [await token.getAddress()],
            [calldata],
            timeStamp,
            nonce,
          ],
        ),
      );
      const intentHash = ethers.keccak256(
        abiCoder.encode(
          ["address", "bytes32"],
          [await inbox.getAddress(), intermediateHash],
        ),
      );
      const fulfillData = [
        sourceChainID,
        [await token.getAddress()],
        [calldata],
        timeStamp,
        nonce,
        await claimant.getAddress(),
        intentHash,
        await metalayerProver.getAddress(),
        [], // empty reads array
      ];

      await token.connect(solver).transfer(await inbox.getAddress(), amount);

      expect(await prover.provenIntents(intentHash)).to.eq(ethers.ZeroAddress);

      await expect(
        inbox.connect(solver).fulfillMetalayerInstant(...fulfillData, {
          value: 1234, // Any value since TestRouter doesn't enforce fees
        }),
      )
        .to.emit(metalayerProver, "IntentProven")
        .withArgs(intentHash, await claimant.getAddress());

      expect(await prover.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      );
    });

    it("works end to end with reads", async () => {
      const prover = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await router.getAddress(), await inbox.getAddress());
      await inbox.connect(owner).setRouter(await router.getAddress());
      await token.mint(solver.address, amount);
      const sourceChainID = 12345;
      const calldata = await encodeTransfer(
        await claimant.getAddress(),
        amount,
      );
      const timeStamp = Math.floor(Date.now() / 1000) + 1000;
      const nonce = ethers.encodeBytes32String("0x987");
      const intermediateHash = ethers.keccak256(
        abiCoder.encode(
          ["uint256", "uint256", "address[]", "bytes[]", "uint256", "bytes32"],
          [
            sourceChainID,
            (await owner.provider.getNetwork()).chainId,
            [await token.getAddress()],
            [calldata],
            timeStamp,
            nonce,
          ],
        ),
      );
      const intentHash = ethers.keccak256(
        abiCoder.encode(
          ["address", "bytes32"],
          [await inbox.getAddress(), intermediateHash],
        ),
      );

      const reads = [
        {
          sourceChainId: 1,
          sourceContract: ethers.Wallet.createRandom().address,
          callData: abiCoder.encode(["uint256"], [1234]),
        },
      ];

      const fulfillData = [
        sourceChainID,
        [await token.getAddress()],
        [calldata],
        timeStamp,
        nonce,
        await claimant.getAddress(),
        intentHash,
        await prover.getAddress(),
        reads,
      ];

      await token.connect(solver).transfer(await inbox.getAddress(), amount);

      expect(await prover.provenIntents(intentHash)).to.eq(ethers.ZeroAddress);

      await expect(
        inbox.connect(solver).fulfillMetalayerInstant(...fulfillData, {
          value: 1234, // Any value since TestRouter doesn't enforce fees
        }),
      )
        .to.emit(prover, "IntentProven")
        .withArgs(intentHash, await claimant.getAddress());

      expect(await prover.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      );

      const storedRead = await router.reads(0);
      expect(storedRead.sourceChainId).to.eq(reads[0].sourceChainId);
      expect(storedRead.sourceContract).to.eq(reads[0].sourceContract);
      expect(storedRead.callData).to.eq(reads[0].callData);
    });

    it("should emit if intent is already proven", async () => {
      metalayerProver = await (
        await ethers.getContractFactory("MetalayerProver")
      ).deploy(await owner.getAddress(), await inbox.getAddress());

      const intentHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
      const claimantAddress = await claimant.getAddress();
      const msgBody = abiCoder.encode(
        ["bytes32[]", "address[]"],
        [[intentHash], [claimantAddress]],
      );

      await metalayerProver
        .connect(owner)
        .handle(12345, await inbox.getAddress(), msgBody, [], []);

      await expect(
        metalayerProver
          .connect(owner)
          .handle(12345, await inbox.getAddress(), msgBody, [], []),
      )
        .to.emit(metalayerProver, "IntentAlreadyProven")
        .withArgs(intentHash);

      expect(await metalayerProver.provenIntents(intentHash)).to.eq(
        claimantAddress,
      );
    });
  });
});
