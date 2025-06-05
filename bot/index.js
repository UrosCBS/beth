const { Telegraf, Markup } = require('telegraf');
const { ethers } = require('ethers');
const { MongoClient } = require('mongodb');
require('dotenv').config();

// Initialize bot with your token
const bot = new Telegraf(process.env.BOT_TOKEN, {
    telegram: {
        apiRoot: 'https://api.telegram.org',
        timeout: 30000, // 30 seconds timeout
        retryAfter: 1, // retry after 1 second
        maxRetries: 3 // maximum number of retries
    }
});

// Initialize MongoDB
const mongoClient = new MongoClient(process.env.MONGODB_URI);
let db;

// Initialize Ethereum provider and contract
const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
const contractAddress = process.env.CONTRACT_ADDRESS;
const contractABI = require('./TelegramMultiTokenPriceBetting.json').abi;

const nftContractAddress = process.env.NFT_CONTRACT_ADDRESS;
const nftContractABI = require('./BetNFT.json').abi;
const contract = new ethers.Contract(contractAddress, contractABI, provider);

const nftContract = new ethers.Contract(nftContractAddress, nftContractABI, provider);

// Initialize wallet for signing transactions
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
const contractWithSigner = contract.connect(wallet);
const nftContractWithSigner = nftContract.connect(wallet);


let currentTokenID = 0; // Start token ID for NFT minting


// Connect to MongoDB
async function connectDB() {
    try {
        await mongoClient.connect();
        db = mongoClient.db('betting_bot');
        console.log('Connected to MongoDB');
    } catch (error) {
        console.error('MongoDB connection error:', error);
        process.exit(1);
    }
}

// Generate wallet for user
async function generateWallet(userId) {
    const wallet = ethers.Wallet.createRandom();
    await db.collection('wallets').insertOne({
        userId,
        address: wallet.address,
        privateKey: wallet.privateKey,
        createdAt: new Date()
    });
    return wallet;
}

// Get user wallet
async function getUserWallet(userId) {
    return await db.collection('wallets').findOne({ userId });
}

// Main menu keyboard
const mainMenu = Markup.keyboard([
    ['📊 Active Bets', '🎯 My Bets'],
    ['💰 Connect Wallet', '❓ Help'],
    ['📈 Create Bet']
]).resize();

// Command handlers
bot.command('start', async (ctx) => {
    await ctx.reply(
        'Welcome to the Decentralized Betting Bot! 🎲\n\n' +
        'This bot allows you to bet on cryptocurrency price movements using smart contracts.\n\n' +
        'Please use the menu below to navigate:',
        mainMenu
    );
});

bot.command('help', async (ctx) => {
    await ctx.reply(
        '🤖 Bot Help & Instructions\n\n' +
        '1. Connect Wallet:\n' +
        '   - Click "Connect Wallet" to generate a new wallet\n' +
        '   - Fund your wallet with ETH to start betting\n\n' +
        '2. Create Bet:\n' +
        '   - Select a token (ETH, BTC, LINK)\n' +
        '   - Choose bet duration\n' +
        '   - Set minimum bet amount\n\n' +
        '3. Place Bet:\n' +
        '   - Select bet ID\n' +
        '   - Choose direction (Higher/Lower)\n' +
        '   - Enter bet amount\n\n' +
        '4. View Bets:\n' +
        '   - Check active bets\n' +
        '   - View your active bets\n' +
        '   - Track bet results\n\n' +
        '💰 Rewards are automatically distributed to winners after each round.\n' +
        '⚠️ Minimum bet: 0.001 ETH\n' +
        '⏱️ Bet duration: 5 minutes\n\n' +
        'Need more help? Contact support.',
        mainMenu
    );
});

// Handle "Connect Wallet" button
bot.hears('💰 Connect Wallet', async (ctx) => {
    const userId = ctx.from.id;
    let userWallet = await getUserWallet(userId);

    if (!userWallet) {
        const wallet = await generateWallet(userId);
        await ctx.reply(
            '🎉 New wallet generated!\n\n' +
            `Address: \`${wallet.address}\`\n\n` +
            'To start betting:\n' +
            '1. Send ETH to this address\n' +
            '2. Wait for confirmation\n' +
            '3. Start placing bets!\n\n' +
            '⚠️ Keep your private key safe and never share it!',
            { parse_mode: 'Markdown' }
        );
    } else {
        await ctx.reply(
            'Your wallet is already connected!\n\n' +
            `Address: \`${userWallet.address}\`\n\n` +
            'Current balance: ' + ethers.utils.formatEther(await provider.getBalance(userWallet.address)) + ' ETH',
            { parse_mode: 'Markdown' }
        );
    }
});

// Handle "Create Bet" button
bot.hears('📈 Create Bet', async (ctx) => {
    const tokenKeyboard = Markup.keyboard([
        ['ETH', 'BTC', 'LINK'],
        ['🔙 Back to Menu']
    ]).resize();

    await ctx.reply('Select a token to create bet:', tokenKeyboard);
});

// Handle token selection for bet creation
bot.hears(['ETH', 'BTC', 'LINK'], async (ctx) => {
    const tokenSymbol = ctx.message.text;
    const tokenId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(tokenSymbol));

    try {
        const tokenInfo = await contract.tokens(tokenId);
        if (!tokenInfo.isActive) {
            await ctx.reply(`Token ${tokenSymbol} is not active or not supported.`, mainMenu);
            return;
        }

        await ctx.reply('Creating a bet...');

        const tx = await contractWithSigner.createBet(tokenId, { gasLimit: 500000 });
        const receipt = await tx.wait();

        if (receipt.status === 1) {
            const currentBetId = await contract.currentBetId();
            await ctx.reply(
                `✅ Bet created successfully for ${tokenSymbol}!\n\n` +
                `Bet ID: ${currentBetId}\n` +
                `To place a bet:\n` +
                `1. Use /placebet ${currentBetId} <higher/lower> <amount>\n` +
                `2. Example: /placebet ${currentBetId} higher 0.1\n\n` +
                `⏱️ Bet duration: 5 minutes\n` +
                `💰 Minimum bet: 0.001 ETH`,
                mainMenu
            );
        }
    } catch (error) {
        console.error('Error creating bet:', error);
        await ctx.reply('Sorry, there was an error creating the bet.', mainMenu);
    }
});

// Handle "Active Bets" button
bot.hears('📊 Active Bets', async (ctx) => {
    try {
        const currentBetId = await contract.currentBetId();
        if (currentBetId.eq(0)) {
            await ctx.reply('No active bets at the moment.', mainMenu);
            return;
        }

        let message = '📊 Active Bets:\n\n';
        for (let i = 1; i <= currentBetId.toNumber(); i++) {
            const bet = await contract.bets(i);
            
            if (bet.status === 0) { // ACTIVE
                const tokenInfo = await contract.tokens(bet.tokenId);
                const timeLeft = Math.max(0, bet.endTime.toNumber() - Math.floor(Date.now() / 1000));
                
                message += `ID: ${bet.id}\n` +
                          `Token: ${tokenInfo.symbol}\n` +
                          `Start Price: ${ethers.utils.formatUnits(bet.startPrice, tokenInfo.decimals)}\n` +
                          `Time Left: ${Math.floor(timeLeft / 60)}m ${timeLeft % 60}s\n` +
                          `Total Pool Higher: ${ethers.utils.formatEther(bet.totalPoolHigher)} ETH\n` +
                          `Total Pool Lower: ${ethers.utils.formatEther(bet.totalPoolLower)} ETH\n\n`;
            }
        }
        await ctx.reply(message, mainMenu);
    } catch (error) {
        console.error('Error fetching bets:', error);
        await ctx.reply('Sorry, there was an error fetching the bets.', mainMenu);
    }
});

// Handle "My Bets" button
bot.hears('🎯 My Bets', async (ctx) => {
    const userId = ctx.from.id;
    const userWallet = await getUserWallet(userId);

    if (!userWallet) {
        await ctx.reply('Please connect your wallet first using the "Connect Wallet" button.', mainMenu);
        return;
    }

    try {
        const currentBetId = await contract.currentBetId();
        if (currentBetId.eq(0)) {
            await ctx.reply('No bets have been created yet.', mainMenu);
            return;
        }

        let message = '🎯 Your Active Bets:\n\n';
        let hasBets = false;

        for (let i = 1; i <= currentBetId.toNumber(); i++) {
            const bet = await contract.bets(i);
            const userBet = await contract.userBets(i, userWallet.address);
            
            if (userBet.amount.gt(0) && bet.status === 0) { // ACTIVE
                hasBets = true;
                const tokenInfo = await contract.tokens(bet.tokenId);
                message += `ID: ${bet.id}\n` +
                          `Token: ${tokenInfo.symbol}\n` +
                          `Amount: ${ethers.utils.formatEther(userBet.amount)} ETH\n` +
                          `Direction: ${userBet.direction === 0 ? 'HIGHER' : 'LOWER'}\n\n`;
            }
        }

        if (!hasBets) {
            message = 'You have no active bets.';
        }

        await ctx.reply(message, mainMenu);
    } catch (error) {
        console.error('Error fetching user bets:', error);
        await ctx.reply('Sorry, there was an error fetching your bets.', mainMenu);
    }
});

// Handle "Back to Menu" button
bot.hears('🔙 Back to Menu', async (ctx) => {
    await ctx.reply('Main Menu:', mainMenu);
});

// Place bet command
bot.command('placebet', async (ctx) => {
    const userId = ctx.from.id;
    const userWallet = await getUserWallet(userId);

    if (!userWallet) {
        await ctx.reply('Please connect your wallet first using the "Connect Wallet" button.', mainMenu);
        return;
    }

    const args = ctx.message.text.split(' ').slice(1);
    if (args.length < 3) {
        await ctx.reply(
            'Please provide bet ID, direction (higher/lower), and amount in ETH.\n' +
            'Example: /placebet 1 higher 0.1',
            mainMenu
        );
        return;
    }

    const betId = parseInt(args[0]);
    const direction = args[1].toLowerCase();
    const amount = parseFloat(args[2]);

    if (isNaN(betId) || isNaN(amount) || amount <= 0) {
        await ctx.reply('Invalid bet ID or amount. Please provide valid numbers.', mainMenu);
        return;
    }

    if (direction !== 'higher' && direction !== 'lower') {
        await ctx.reply('Invalid direction. Please use "higher" or "lower".', mainMenu);
        return;
    }

    try {
        const bet = await contract.bets(betId);
        if (bet.status !== 0) { // 0 = ACTIVE
            await ctx.reply('This bet is not active.', mainMenu);
            return;
        }

        const directionValue = direction === 'higher' ? 0 : 1;
        const amountWei = ethers.utils.parseEther(amount.toString());

        // Create a new wallet instance for the user
        const userWalletInstance = new ethers.Wallet(userWallet.privateKey, provider);
        const userContract = contract.connect(userWalletInstance);

        const tx = await userContract.placeBet(betId, directionValue, { value: amountWei, gasLimit: 5000000 });
        await ctx.reply(`Placing your bet... `, mainMenu);
        
        const receipt = await tx.wait();
        if (receipt.status === 1) {
            await ctx.reply(`✅ Bet placed successfully! Transaction hash: ${tx.hash}`, mainMenu);
        } else {
            await ctx.reply('❌ Transaction failed. Please try again.', mainMenu);
        }
    } catch (error) {
        console.error('Error placing bet:', error);
        await ctx.reply(
            'Sorry, there was an error placing your bet. ' +
            'Please make sure you have enough ETH and the bet is still active.',
            mainMenu
        );
    }
});

// Automatic bet resolution check
async function checkAndResolveBets() {
    try {
        const currentBetId = await contract.currentBetId();
        if (currentBetId.eq(0)) return;

        for (let i = 1; i <= currentBetId.toNumber(); i++) {
            const bet = await contract.bets(i);
            if (bet.status === 0 && // ACTIVE
                bet.endTime.toNumber() <= Math.floor(Date.now() / 1000)) {
                await contractWithSigner.resolveBet(i, { gasLimit: 5000000 });
                // Get all participants for this bet
                const participants = await contract.getBetParticipants(i);
                
                // Get bet details
                const betDetails = await contract.bets(i);
                const tokenId = betDetails.tokenId;
                const tokenInfo = await contract.tokens(tokenId);
                const endPrice = betDetails.endPrice;
                const startPrice = betDetails.startPrice;
                const winningDirection = endPrice > startPrice ? 'HIGHER' : 'LOWER';
                
                // Notify all participants about the bet resolution
                for (const participant of participants) {
                    const userBet = await contract.userBets(i, participant);
                    const betAmount = ethers.utils.formatEther(userBet.amount);
                    const userDirection = userBet.direction === 0 ? 'HIGHER' : 'LOWER';
                    const won = userDirection === winningDirection;

                    // Find the user ID associated with this wallet address
                    const userWallet = await db.collection('wallets').findOne({ address: participant });
                    if (userWallet) {
                        // If user won, try to claim their rewards automatically
                        if (won) {
                            try {
                                const userWalletInstance = new ethers.Wallet(userWallet.privateKey, provider);
                                const userContract = contract.connect(userWalletInstance);
                                const tx = await userContract.claimReward(i, { gasLimit: 5000000 });

                                const tx2 = await nftContract.mint(participant, currentTokenID, { gasLimit: 5000000 });

                                currentTokenID++;

                                const reward = await userContract.calculatePotentialReward(i, participant);
                                const rewardEth = ethers.utils.formatEther(reward);
                                
                                // Send notification using bot.telegram.sendMessage
                                await bot.telegram.sendMessage(
                                    userWallet.userId,
                                    `🎁 Your reward for bet #${i} has been automatically claimed!\n` +
                                    `Amount: ${rewardEth} ETH`,
                                    mainMenu
                                );
                            } catch (error) {
                                console.error(`Failed to auto-claim reward for bet ${i}, participant ${participant}:`, error);
                                // Send notification about failed claim
                                await bot.telegram.sendMessage(
                                    userWallet.userId,
                                    `⚠️ Automatic reward claim failed for bet #${i}. Please claim your reward manually.`,
                                    mainMenu
                                );
                            }
                        } else {
                            // Notify user about lost bet
                            await bot.telegram.sendMessage(
                                userWallet.userId,
                                `Bet #${i} has been resolved. Unfortunately, you did not win this time.`,
                                mainMenu
                            );
                        }
                    }
                }
                console.log(`Bet ${i} resolved automatically`);
            }
        }
    } catch (error) {
        console.error('Error in automatic bet resolution:', error);
    }
}

// Run bet resolution check every minute
setInterval(checkAndResolveBets, 60000);

// Error handling
bot.catch((err, ctx) => {
    console.error('Bot error:', err);
    ctx.reply('An error occurred while processing your request.', mainMenu);
});

// Start the bot with retry logic
async function startBot() {
    let retries = 0;
    const maxRetries = 5;
    const retryDelay = 5000; // 5 seconds

    while (retries < maxRetries) {
        try {
            await connectDB();
            await bot.launch();
            console.log('Bot is running...');
            break;
        } catch (error) {
            retries++;
            console.error(`Failed to start bot (attempt ${retries}/${maxRetries}):`, error.message);
            
            if (retries === maxRetries) {
                console.error('Max retries reached. Could not start the bot.');
                process.exit(1);
            }
            
            console.log(`Retrying in ${retryDelay/1000} seconds...`);
            await new Promise(resolve => setTimeout(resolve, retryDelay));
        }
    }
}

// Start the bot
startBot().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});

// Enable graceful stop
process.once('SIGINT', () => {
    bot.stop('SIGINT');
    mongoClient.close();
});
process.once('SIGTERM', () => {
    bot.stop('SIGTERM');
    mongoClient.close();
}); 