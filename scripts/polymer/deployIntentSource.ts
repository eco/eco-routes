import { ethers } from "hardhat";
import hre from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  const nonce = await deployer.getNonce();
  console.log("deploying intent source with nonce:", nonce);
  const IntentSourceFactory = await ethers.getContractFactory("IntentSource");
  const intentSource = await IntentSourceFactory.deploy();

  await intentSource.waitForDeployment();
  const intentSourceAddr = await intentSource.getAddress();
  console.log("intent source deployed at:", intentSourceAddr);

  await hre.run("verify:verify", {
    address: intentSourceAddr,
    constructorArguments: [], });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});