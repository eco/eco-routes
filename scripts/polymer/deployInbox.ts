import { ethers } from "hardhat";
import hre from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  const nonce = await deployer.getNonce();
  console.log("deploying inbox with nonce:", nonce);
  const inboxFactory = await ethers.getContractFactory("Inbox");
  const inbox = await inboxFactory.deploy(
    deployer.address,
    true,
    [deployer.address]
  );

  await inbox.waitForDeployment();
  const inboxAddr = await inbox.getAddress();
  console.log("inbox deployed at:", inboxAddr);

 
  await new Promise(resolve => setTimeout(resolve, 5000));
  
  await hre.run("verify:verify", {
    address: inboxAddr,
    constructorArguments: [
      deployer.address,
      true,
      [deployer.address]
    ],
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});