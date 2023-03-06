const core = require('@actions/core');
const github = require('@actions/github');
const { ethers } = require("ethers-quorum");

/**
 * Usage: `node lookup.js "http://localhost:8545" "ou.latest"
 */
try {
    const addressDirectoryAddress = "0xAD0000004ed6FF7273E2F82606D432167053e5Ac";

    async function main() {
        const rpcUrl = core.getInput('rpc-url');
        const contractKey = core.getInput('lookup-key');
        const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
        const abi = ["function lookup(string) public view returns (address,string,string[])"];
        const AddressDirectoryContract = new ethers.Contract(addressDirectoryAddress, abi, provider);
        const result = await AddressDirectoryContract.lookup(contractKey);
        const resultAddress = result[0];
        console.log(resultAddress);
        core.setOutput("contract-address", resultAddress);
    }

    if (require.main === module) {
        main();
    }

    module.exports = exports = main

} catch (error) {
  core.setFailed(error.message);
}

