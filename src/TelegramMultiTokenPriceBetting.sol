// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract TelegramMultiTokenPriceBetting is ReentrancyGuard, Ownable, Pausable {
    enum Direction {
        HIGHER,
        LOWER
    }
    enum BetStatus {
        ACTIVE,
        CLOSED,
        RESOLVED
    }

    struct TokenInfo {
        string symbol;
        string name;
        AggregatorV3Interface priceOracle;
        bool isActive;
        uint8 decimals;
    }

    struct Bet {
        uint256 id;
        bytes32 tokenId;
        uint256 startTime;
        uint256 endTime;
        int256 startPrice;
        int256 endPrice;
        uint256 totalPoolHigher;
        uint256 totalPoolLower;
        uint256 totalBets;
        BetStatus status;
        bool resolved;
    }

    struct UserBet {
        uint256 amount;
        Direction direction;
        bool claimed;
    }

    struct TokenConfig {
        string symbol;
        string name;
        address priceOracle;
    }

    // State variables
    mapping(bytes32 => TokenInfo) public tokens;
    mapping(uint256 => Bet) public bets;
    mapping(uint256 => mapping(address => UserBet)) public userBets;
    mapping(uint256 => address[]) public betParticipants;
    mapping(bytes32 => uint256[]) public tokenBetHistory; // Track bet IDs for each token

    uint256 public currentBetId;
    uint256 public constant BET_DURATION = 5 minutes;
    uint256 public constant BETTING_CUTOFF = 30 seconds; // Stop betting 30s before end
    uint256 public minimumBet = 0.001 ether;
    uint256 public platformFeePercent = 200; // 2% (200/10000)

    address public botAddress;

    // Events
    event TokenAdded(bytes32 indexed tokenId, string symbol, string name, address oracle);
    event TokenUpdated(bytes32 indexed tokenId, address newOracle);
    event TokenStatusChanged(bytes32 indexed tokenId, bool isActive);
    event BetCreated(
        uint256 indexed betId, bytes32 indexed tokenId, uint256 startTime, uint256 endTime, int256 startPrice
    );
    event BetPlaced(uint256 indexed betId, address indexed user, uint256 amount, Direction direction);
    event BetResolved(uint256 indexed betId, bytes32 indexed tokenId, int256 endPrice, Direction winningDirection);
    event RewardClaimed(uint256 indexed betId, address indexed user, uint256 amount);
    event BotAddressUpdated(address oldBot, address newBot);
    event MinimumBetUpdated(uint256 oldMin, uint256 newMin);

    modifier onlyBot() {
        require(msg.sender == botAddress, "Only bot can call this function");
        _;
    }

    modifier validBet(uint256 _betId) {
        require(_betId <= currentBetId && _betId > 0, "Invalid bet ID");
        _;
    }

    modifier validToken(bytes32 _tokenId) {
        require(tokens[_tokenId].isActive, "Token not supported or inactive");
        _;
    }

    constructor(address _botAddress, TokenConfig[] memory _initialTokens) Ownable(msg.sender) {
        botAddress = _botAddress;
        currentBetId = 0;

        // Initialize tokens from constructor
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            bytes32 tokenId = keccak256(abi.encodePacked(_initialTokens[i].symbol));
            require(address(tokens[tokenId].priceOracle) == address(0), "Token already exists");

            AggregatorV3Interface oracle = AggregatorV3Interface(_initialTokens[i].priceOracle);
            uint8 decimals = oracle.decimals();

            tokens[tokenId] = TokenInfo({
                symbol: _initialTokens[i].symbol,
                name: _initialTokens[i].name,
                priceOracle: oracle,
                isActive: true,
                decimals: decimals
            });

            emit TokenAdded(tokenId, _initialTokens[i].symbol, _initialTokens[i].name, _initialTokens[i].priceOracle);
        }
    }

    /**
     * @dev Add a new token with its price oracle
     */
    function addToken(string memory _symbol, string memory _name, address _priceOracle) external onlyOwner {
        bytes32 tokenId = keccak256(abi.encodePacked(_symbol));
        require(address(tokens[tokenId].priceOracle) == address(0), "Token already exists");

        AggregatorV3Interface oracle = AggregatorV3Interface(_priceOracle);
        uint8 decimals = oracle.decimals();

        tokens[tokenId] =
            TokenInfo({symbol: _symbol, name: _name, priceOracle: oracle, isActive: true, decimals: decimals});

        emit TokenAdded(tokenId, _symbol, _name, _priceOracle);
    }

    /**
     * @dev Update price oracle for existing token
     */
    function updateTokenOracle(bytes32 _tokenId, address _newOracle) external onlyOwner {
        require(address(tokens[_tokenId].priceOracle) != address(0), "Token does not exist");

        tokens[_tokenId].priceOracle = AggregatorV3Interface(_newOracle);
        tokens[_tokenId].decimals = AggregatorV3Interface(_newOracle).decimals();

        emit TokenUpdated(_tokenId, _newOracle);
    }

    /**
     * @dev Set token active/inactive status
     */
    function setTokenStatus(bytes32 _tokenId, bool _isActive) external onlyOwner {
        require(address(tokens[_tokenId].priceOracle) != address(0), "Token does not exist");
        tokens[_tokenId].isActive = _isActive;
        emit TokenStatusChanged(_tokenId, _isActive);
    }

    /**
     * @dev Create a new betting round for specific token (called by Telegram bot)
     */
    function createBet(bytes32 _tokenId) external onlyBot whenNotPaused validToken(_tokenId) {
        currentBetId++;

        (, int256 currentPrice,, uint256 updatedAt,) = tokens[_tokenId].priceOracle.latestRoundData();

        if (updatedAt < block.timestamp - 20 * 60 /* 20 minutes */ ) {
            revert("stale price feed");
        }

        bets[currentBetId] = Bet({
            id: currentBetId,
            tokenId: _tokenId,
            startTime: block.timestamp,
            endTime: block.timestamp + BET_DURATION,
            startPrice: currentPrice,
            endPrice: 0,
            totalPoolHigher: 0,
            totalPoolLower: 0,
            totalBets: 0,
            status: BetStatus.ACTIVE,
            resolved: false
        });

        tokenBetHistory[_tokenId].push(currentBetId);

        emit BetCreated(currentBetId, _tokenId, block.timestamp, block.timestamp + BET_DURATION, currentPrice);
    }

    /**
     * @dev Place a bet on price direction
     */
    function placeBet(uint256 _betId, Direction _direction)
        external
        payable
        validBet(_betId)
        nonReentrant
        whenNotPaused
    {
        require(msg.value >= minimumBet, "Bet amount too low");

        Bet storage bet = bets[_betId];
        require(bet.status == BetStatus.ACTIVE, "Bet is not active");
        require(tokens[bet.tokenId].isActive, "Token is not active");
        require(block.timestamp < bet.endTime - BETTING_CUTOFF, "Betting period closed");
        require(userBets[_betId][msg.sender].amount == 0, "User already bet on this round");

        // Record user bet
        userBets[_betId][msg.sender] = UserBet({amount: msg.value, direction: _direction, claimed: false});

        // Add to participants list
        betParticipants[_betId].push(msg.sender);

        // Update pool totals
        if (_direction == Direction.HIGHER) {
            bet.totalPoolHigher += msg.value;
        } else {
            bet.totalPoolLower += msg.value;
        }

        bet.totalBets++;

        emit BetPlaced(_betId, msg.sender, msg.value, _direction);
    }

    /**
     * @dev Resolve a bet (can be called by anyone after bet ends)
     */
    function resolveBet(uint256 _betId) external validBet(_betId) {
        _resolveBet(_betId);
    }

    /**
     * @dev Internal function to resolve bet
     */
    function _resolveBet(uint256 _betId) internal {
        Bet storage bet = bets[_betId];
        require(bet.status == BetStatus.ACTIVE, "Bet already resolved");
        require(block.timestamp >= bet.endTime, "Bet still active");

        (, int256 endPrice,,,) = tokens[bet.tokenId].priceOracle.latestRoundData();

        // STA AKO BUDE STALE PRICE OVDE, A BET TREBA DA SE RESOLVUJE

        bet.endPrice = endPrice;
        bet.status = BetStatus.RESOLVED;
        bet.resolved = true;

        Direction winningDirection = endPrice > bet.startPrice ? Direction.HIGHER : Direction.LOWER;

        emit BetResolved(_betId, bet.tokenId, endPrice, winningDirection);
    }

    /**
     * @dev Claim reward for a winning bet
     */
    function claimReward(uint256 _betId) external validBet(_betId) nonReentrant {
        Bet storage bet = bets[_betId];
        require(bet.resolved, "Bet not resolved yet");

        UserBet storage userBet = userBets[_betId][msg.sender];
        require(userBet.amount > 0, "No bet found");
        require(!userBet.claimed, "Reward already claimed");

        // Determine if user won
        Direction winningDirection = bet.endPrice > bet.startPrice ? Direction.HIGHER : Direction.LOWER;
        require(userBet.direction == winningDirection, "Bet lost");

        // Calculate reward
        uint256 totalPool = bet.totalPoolHigher + bet.totalPoolLower;
        uint256 winningPool = winningDirection == Direction.HIGHER ? bet.totalPoolHigher : bet.totalPoolLower;

        // If no one bet on the losing side, winners get their money back minus platform fee
        uint256 platformFee = (totalPool * platformFeePercent) / 10000;
        uint256 rewardPool = totalPool - platformFee;

        uint256 userReward = (userBet.amount * rewardPool) / winningPool;

        userBet.claimed = true;

        // Transfer reward to user first for security
        payable(msg.sender).transfer(userReward);

        // Transfer platform fee to owner
        if (platformFee > 0) {
            payable(owner()).transfer(platformFee);
        }

        emit RewardClaimed(_betId, msg.sender, userReward);
    }

    /**
     * @dev Batch resolve multiple bets (gas optimization)
     */
    function resolveBets(uint256[] calldata _betIds) external {
        for (uint256 i = 0; i < _betIds.length; i++) {
            if (_betIds[i] <= currentBetId && _betIds[i] > 0) {
                Bet storage bet = bets[_betIds[i]];
                if (bet.status == BetStatus.ACTIVE && block.timestamp >= bet.endTime) {
                    _resolveBet(_betIds[i]);
                }
            }
        }
    }

    /**
     * @dev Get token information
     */
    function getTokenInfo(bytes32 _tokenId) external view returns (TokenInfo memory) {
        return tokens[_tokenId];
    }

    /**
     * @dev Get token ID by symbol
     */
    function getTokenId(string memory _symbol) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_symbol));
    }

    /**
     * @dev Get bet history for a specific token
     */
    function getTokenBetHistory(bytes32 _tokenId) external view returns (uint256[] memory) {
        return tokenBetHistory[_tokenId];
    }

    /**
     * @dev Get latest price for a token
     */
    function getLatestPrice(bytes32 _tokenId) external view validToken(_tokenId) returns (int256, uint256) {
        (, int256 price,, uint256 updatedAt,) = tokens[_tokenId].priceOracle.latestRoundData();
        return (price, updatedAt);
    }

    /**
     * @dev Get bet details
     */
    function getBetDetails(uint256 _betId) external view validBet(_betId) returns (Bet memory) {
        return bets[_betId];
    }

    /**
     * @dev Get user bet details
     */
    function getUserBet(uint256 _betId, address _user) external view validBet(_betId) returns (UserBet memory) {
        return userBets[_betId][_user];
    }

    /**
     * @dev Get current active bet ID
     */
    function getCurrentBetId() external view returns (uint256) {
        return currentBetId;
    }

    /**
     * @dev Check if bet can be resolved
     */
    function canResolveBet(uint256 _betId) external view validBet(_betId) returns (bool) {
        Bet memory bet = bets[_betId];
        return bet.status == BetStatus.ACTIVE && block.timestamp >= bet.endTime;
    }

    /**
     * @dev Calculate potential reward for a user
     */
    function calculatePotentialReward(uint256 _betId, address _user) external view validBet(_betId) returns (uint256) {
        Bet storage bet = bets[_betId];
        UserBet storage userBet = userBets[_betId][_user];

        if (userBet.amount == 0 || !bet.resolved) {
            return 0;
        }

        Direction winningDirection = bet.endPrice > bet.startPrice ? Direction.HIGHER : Direction.LOWER;
        if (userBet.direction != winningDirection) {
            return 0;
        }

        uint256 totalPool = bet.totalPoolHigher + bet.totalPoolLower;
        uint256 winningPool = winningDirection == Direction.HIGHER ? bet.totalPoolHigher : bet.totalPoolLower;
        uint256 platformFee = (totalPool * platformFeePercent) / 10000;
        uint256 rewardPool = totalPool - platformFee;

        return (userBet.amount * rewardPool) / winningPool;
    }

    /**
     * @dev Get active bets for multiple tokens
     */
    function getActiveBetsForTokens(bytes32[] calldata _tokenIds) external view returns (uint256[] memory activeBets) {
        uint256 count = 0;
        uint256[] memory tempBets = new uint256[](currentBetId);

        for (uint256 i = 1; i <= currentBetId; i++) {
            Bet storage bet = bets[i];
            if (bet.status == BetStatus.ACTIVE) {
                for (uint256 j = 0; j < _tokenIds.length; j++) {
                    if (bet.tokenId == _tokenIds[j]) {
                        tempBets[count] = i;
                        count++;
                        break;
                    }
                }
            }
        }

        activeBets = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            activeBets[i] = tempBets[i];
        }
    }

    // Admin functions
    function setBotAddress(address _newBot) external onlyOwner {
        address oldBot = botAddress;
        botAddress = _newBot;
        emit BotAddressUpdated(oldBot, _newBot);
    }

    function setMinimumBet(uint256 _newMinimum) external onlyOwner {
        uint256 oldMin = minimumBet;
        minimumBet = _newMinimum;
        emit MinimumBetUpdated(oldMin, _newMinimum);
    }

    function setPlatformFee(uint256 _newFeePercent) external onlyOwner {
        require(_newFeePercent <= 1000, "Fee cannot exceed 10%"); // Max 10%
        platformFeePercent = _newFeePercent;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Emergency function to withdraw stuck funds (only if contract is paused)
    function emergencyWithdraw() external onlyOwner {
        require(paused(), "Contract must be paused");
        (bool success,) = owner().call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }

    // Get contract balance
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Get all participants for a specific bet
     * @param _betId The ID of the bet to get participants for
     * @return Array of addresses that participated in the bet
     */
    function getBetParticipants(uint256 _betId) external view validBet(_betId) returns (address[] memory) {
        return betParticipants[_betId];
    }
}
