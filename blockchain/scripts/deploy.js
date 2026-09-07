const hre = require("hardhat");

async function main() {
  const SecureSheRegistry = await hre.ethers.getContractFactory("SecureSheRegistry");
  const registry = await SecureSheRegistry.deploy();
  await registry.waitForDeployment();

  const address = await registry.getAddress();
  console.log("SecureSheRegistry deployed to:", address);
  console.log("Save this address into ../.env as CONTRACT_ADDRESS");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
