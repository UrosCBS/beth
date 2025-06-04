// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/TelegramMultiTokenPriceBetting.sol";

// Mock Chainlink Aggregator for testing
contract MockAggregator {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(int256 initialPrice, uint8 decimals_) {
        _price = initialPrice;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, _updatedAt, _roundId);
    }

    function updatePrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
        _roundId++;
    }
}

contract TelegramMultiTokenPriceBettingTest is Test {
    TelegramMultiTokenPriceBetting public bettingContract;
    MockAggregator public btcOracle;
    MockAggregator public ethOracle;
    MockAggregator public linkOracle;

    address public owner;
    address public bot;
    address public user1;
    address public user2;
    address public user3;

    bytes32 public btcId;
    bytes32 public ethId;
    bytes32 public linkId;

    // Events for testing
    event TokenAdded(bytes32 indexed tokenId, string symbol, string name, address oracle);
    event TokenUpdated(bytes32 indexed tokenId, address newOracle);
    event TokenStatusChanged(bytes32 indexed tokenId, bool isActive);
    event BetCreated(uint256 indexed betId, bytes32 indexed tokenId, uint256 startTime, uint256 endTime, int256 startPrice);
    event BetPlaced(uint256 indexed betId, address indexed user, uint256 amount, TelegramMultiTokenPriceBetting.Direction direction);
    event BetResolved(uint256 indexed betId, bytes32 indexed tokenId, int256 endPrice, TelegramMultiTokenPriceBetting.Direction winningDirection);
    event RewardClaimed(uint256 indexed betId, address indexed user, uint256 amount);
    event BotAddressUpdated(address oldBot, address newBot);
    event MinimumBetUpdated(uint256 oldMin, uint256 newMin);

    function setUp() public {
        owner = address(this);
        bot = makeAddr("bot");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Give users some ETH
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);

        // Deploy mock oracles
        btcOracle = new MockAggregator(50000 * 1e8, 8); // $50,000 BTC
        ethOracle = new MockAggregator(3000 * 1e8, 8);  // $3,000 ETH
        linkOracle = new MockAggregator(15 * 1e8, 8);   // $15 LINK

        // Deploy betting contract
        TelegramMultiTokenPriceBetting.TokenConfig[] memory configs = new TelegramMultiTokenPriceBetting.TokenConfig[](3);
        configs[0] = TelegramMultiTokenPriceBetting.TokenConfig({symbol: "BTC", name: "Bitcoin", priceOracle: address(btcOracle)});
        configs[1] = TelegramMultiTokenPriceBetting.TokenConfig({symbol: "ETH", name: "Ethereum", priceOracle: address(ethOracle)});
        configs[2] = TelegramMultiTokenPriceBetting.TokenConfig({symbol: "LINK", name: "Chainlink", priceOracle: address(linkOracle)});
        bettingContract = new TelegramMultiTokenPriceBetting(bot, configs);

        // // Add tokens
        // bettingContract.addToken("BTC", "Bitcoin", address(btcOracle));
        // bettingContract.addToken("ETH", "Ethereum", address(ethOracle));
        // bettingContract.addToken("LINK", "Chainlink", address(linkOracle));

        // btcId = keccak256(abi.encodePacked("BTC"));
        // ethId = keccak256(abi.encodePacked("ETH"));
        // linkId = keccak256(abi.encodePacked("LINK"));
    }

    // Test Constructor
    function test_Constructor() public {
        TelegramMultiTokenPriceBetting.TokenConfig[] memory configs = new TelegramMultiTokenPriceBetting.TokenConfig[](3);
        configs[0] = TelegramMultiTokenPriceBetting.TokenConfig({symbol: "BTC", name: "Bitcoin", priceOracle: address(btcOracle)});
        configs[1] = TelegramMultiTokenPriceBetting.TokenConfig({symbol: "ETH", name: "Ethereum", priceOracle: address(ethOracle)});
        configs[2] = TelegramMultiTokenPriceBetting.TokenConfig({symbol: "LINK", name: "Chainlink", priceOracle: address(linkOracle)});
        TelegramMultiTokenPriceBetting newContract = new TelegramMultiTokenPriceBetting(bot, configs);
        
        assertEq(newContract.botAddress(), bot);
        assertEq(newContract.owner(), address(this));
        assertEq(newContract.getCurrentBetId(), 0);
        assertEq(newContract.minimumBet(), 0.001 ether);
        assertEq(newContract.platformFeePercent(), 200);
    }

    // Test Token Management
    function test_AddToken() public {
        MockAggregator newOracle = new MockAggregator(100 * 1e8, 8);
        
        vm.expectEmit(true, false, false, true);
        emit TokenAdded(keccak256(abi.encodePacked("TEST")), "TEST", "Test Token", address(newOracle));
        
        bettingContract.addToken("TEST", "Test Token", address(newOracle));
        
        TelegramMultiTokenPriceBetting.TokenInfo memory tokenInfo = bettingContract.getTokenInfo(keccak256(abi.encodePacked("TEST")));
        assertEq(tokenInfo.symbol, "TEST");
        assertEq(tokenInfo.name, "Test Token");
        assertEq(address(tokenInfo.priceOracle), address(newOracle));
        assertTrue(tokenInfo.isActive);
        assertEq(tokenInfo.decimals, 8);
    }

    function test_AddToken_RevertIfAlreadyExists() public {
        vm.prank(owner);
        vm.expectRevert();
        bettingContract.addToken("BTC", "Bitcoin", address(btcOracle));
        console.log("tokenId");
    }

    function test_AddToken_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bettingContract.addToken("TEST", "Test Token", address(btcOracle));
    }

    
}