// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {TelegramMultiTokenPriceBetting} from "../src/TelegramMultiTokenPriceBetting.sol";

contract DeployTelegramBetting is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address botAddress = vm.envAddress("BOT_ADDRESS");

        // Chainlink Price Feed Addresses for Mainnet
        address ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address BTC_USD_FEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
        address LINK_USD_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF;

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
