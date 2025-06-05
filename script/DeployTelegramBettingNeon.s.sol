// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {TelegramMultiTokenPriceBetting} from "../src/TelegramMultiTokenPriceBetting.sol";

contract DeployTelegramBettingNeon is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address botAddress = vm.envAddress("BOT_ADDRESS");

        // Chainlink Price Feed Addresses for Neon Devnet
        address ETH_USD_FEED = 0x7235B04963600fA184f6023696870F49d014416d;
        address BTC_USD_FEED = 0x878738FdbCC9Aa39Ce68Fa3B0B0B93426EcB6417;
        address LINK_USD_FEED = 0xc75E93c4593c23A50cff935F8916774e02c506C7;

        TelegramMultiTokenPriceBetting.TokenConfig[] memory initialTokens =
            new TelegramMultiTokenPriceBetting.TokenConfig[](3);

        initialTokens[0] =
            TelegramMultiTokenPriceBetting.TokenConfig({symbol: "ETH", name: "Ethereum", priceOracle: ETH_USD_FEED});

        initialTokens[1] =
            TelegramMultiTokenPriceBetting.TokenConfig({symbol: "BTC", name: "Bitcoin", priceOracle: BTC_USD_FEED});

        initialTokens[2] =
            TelegramMultiTokenPriceBetting.TokenConfig({symbol: "LINK", name: "Chainlink", priceOracle: LINK_USD_FEED});

        vm.startBroadcast(deployerPrivateKey);

        // TelegramMultiTokenPriceBetting betting = new TelegramMultiTokenPriceBetting(botAddress, initialTokens);

        vm.stopBroadcast();
    }
}
