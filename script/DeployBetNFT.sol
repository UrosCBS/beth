// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {BetNFT} from "../src/BetNFT.sol";

contract DeployBetNFT is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        BetNFT nft = new BetNFT();

        vm.stopBroadcast();
    }
}
