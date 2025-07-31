// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CashCow} from "../src/CashCow.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract CashCowTest is Test {
    using MessageHashUtils for bytes32;

    CashCow public casino;
    ERC20Mock public usdc;
    address public owner;
    uint256 public ownerPrivateKey;
    address public player1;
    address public player2;
    address public attacker;

    // Test constants
    uint256 constant INITIAL_TREASURY = 10000e6; // 10,000 USDC
    uint256 constant BET_AMOUNT = 100e6; // 100 USDC
    uint256 constant PAYOUT_AMOUNT = 200e6; // 200 USDC
    uint256 constant MIN_BET = 10e6; // 10 USDC
    uint256 constant MAX_BET = 10e8; // 1000 USDC

    // Events to test - Updated to match new contract
    event GameCreated(
        bytes32 indexed gameId,
        address indexed player,
        uint256 betAmount,
        address indexed betToken,
        bytes32 gameSeedHash
    );
    event GameWon(bytes32 indexed gameId, address indexed player, uint256 amount, address indexed token);
    event GameLost(bytes32 indexed gameId, address indexed player);
    event GameExpired(bytes32 indexed gameId, address indexed player);
    event BetLimitsUpdated(address indexed token, uint256 min, uint256 max);
    event TreasuryDeposit(uint256 amount, address indexed token);
    event TreasuryWithdrawal(uint256 amount, address indexed token);

    constructor() {
        // Set up accounts
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        attacker = makeAddr("attacker");

        // Deploy contracts
        usdc = new ERC20Mock();
    }

    function setUp() public {
        casino = new CashCow(owner);

        // Set up initial balances
        usdc.mint(owner, INITIAL_TREASURY);
        usdc.mint(player1, 1000e6);
        usdc.mint(player2, 1000e6);

        // Owner adds initial treasury and sets min bet
        vm.startPrank(owner);
        usdc.approve(address(casino), INITIAL_TREASURY);
        casino.addToTreasury(INITIAL_TREASURY, address(usdc));
        casino.updateBetLimits(address(usdc), MIN_BET, MAX_BET);
        vm.stopPrank();
    }

    // ========== HELPER FUNCTIONS ==========

    function signCreateGame(
        bytes32 gameSeedHash,
        bytes32 gameId,
        uint256 betAmount,
        address betToken,
        address player,
        uint256 deadline
    ) public view returns (bytes memory) {
        bytes32 structHash = casino.hashCreateGame(gameSeedHash, gameId, betAmount, betToken, player, deadline);
        bytes32 domainSeparator = casino.domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function signCashout(
        string memory gameSeed,
        bytes32 gameId,
        uint256 payoutAmount,
        address betToken,
        address player,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = casino.hashCashoutGame(gameSeed, gameId, payoutAmount, betToken, player, deadline);
        bytes32 domainSeparator = casino.domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function signLoss(
        string memory gameSeed,
        bytes32 gameId,
        uint256 betAmount,
        address betToken,
        address player,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = casino.hashGameLoss(gameSeed, gameId, betAmount, betToken, player, deadline);
        bytes32 domainSeparator = casino.domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function createGame(address player, bytes32 gameId) internal returns (bytes32) {
        bytes32 gameSeedHash = keccak256("test_seed");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 extra = bytes32(uint256(1)); // Some extra data

        bytes memory signature = signCreateGame(gameSeedHash, gameId, BET_AMOUNT, address(usdc), player, deadline);

        vm.startPrank(player);
        usdc.approve(address(casino), BET_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit GameCreated(gameId, player, BET_AMOUNT, address(usdc), gameSeedHash);

        casino.createGame(gameSeedHash, gameId, BET_AMOUNT, address(usdc), player, extra, signature, deadline);
        vm.stopPrank();

        return gameId;
    }

    // ========== BASIC FUNCTIONALITY TESTS ==========

    function testCreateGame() public {
        assertEq(casino.treasury(address(usdc)), INITIAL_TREASURY);
        assertEq(casino.locked(address(usdc)), 0);

        bytes32 gameId = keccak256("game1");
        createGame(player1, gameId);

        CashCow.Game memory game = casino.getGameDetails(gameId);
        assertEq(game.player, player1);
        assertEq(game.betAmount, BET_AMOUNT);
        assertEq(game.betToken, address(usdc));
        assertEq(uint256(game.status), uint256(CashCow.GameStatus.ACTIVE));
        assertEq(game.payoutAmount, 0);

        // Check that locked funds increased
        assertEq(casino.locked(address(usdc)), BET_AMOUNT);
    }

    function testCashoutWithSignature() public {
        bytes32 gameId = keccak256("game1");
        createGame(player1, gameId);

        uint256 playerBalanceBefore = usdc.balanceOf(player1);
        uint256 treasuryBefore = casino.treasury(address(usdc));
        uint256 lockedBefore = casino.locked(address(usdc));
        uint256 deadline = block.timestamp + 1 hours;

        // Reveal seed must match the default "test_seed"
        bytes memory signature = signCashout("test_seed", gameId, PAYOUT_AMOUNT, address(usdc), player1, deadline);

        vm.expectEmit(true, true, true, true);
        emit GameWon(gameId, player1, PAYOUT_AMOUNT, address(usdc));

        // Anyone can trigger cashout with valid signature
        vm.prank(player2);
        casino.cashOut(gameId, PAYOUT_AMOUNT, "test_seed", deadline, signature);

        // Check game state
        CashCow.Game memory game = casino.getGameDetails(gameId);
        assertEq(uint256(game.status), uint256(CashCow.GameStatus.WON));
        assertEq(game.payoutAmount, PAYOUT_AMOUNT);
        assertEq(game.gameSeed, "test_seed");

        // Check balances
        assertEq(usdc.balanceOf(player1), playerBalanceBefore + PAYOUT_AMOUNT);

        // Treasury should lose only the excess over the bet
        uint256 excess = PAYOUT_AMOUNT - BET_AMOUNT;
        assertEq(casino.treasury(address(usdc)), treasuryBefore - excess);

        // Locked funds released
        assertEq(casino.locked(address(usdc)), lockedBefore - BET_AMOUNT);
    }

    function testMarkGameAsLost() public {
        bytes32 gameId = keccak256("game1");
        createGame(player1, gameId);

        uint256 treasuryBefore = casino.treasury(address(usdc));
        uint256 lockedBefore = casino.locked(address(usdc));
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signLoss("test_seed", gameId, BET_AMOUNT, address(usdc), player1, deadline);

        vm.expectEmit(true, true, false, true);
        emit GameLost(gameId, player1);

        vm.prank(player2);
        casino.markGameAsLost(gameId, "test_seed", deadline, signature);

        // Check game state
        CashCow.Game memory game = casino.getGameDetails(gameId);
        assertEq(uint256(game.status), uint256(CashCow.GameStatus.LOST));
        assertEq(game.gameSeed, "test_seed");

        // Treasury recovers the bet
        assertEq(casino.treasury(address(usdc)), treasuryBefore + BET_AMOUNT);

        // Locked funds released
        assertEq(casino.locked(address(usdc)), lockedBefore - BET_AMOUNT);
    }

    function testMinBetEnforcement() public {
        bytes32 gameId = keccak256("minbet_test");
        bytes32 gameSeedHash = keccak256(bytes("test_seed"));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 tooSmallBet = MIN_BET - 1;

        bytes memory signature = signCreateGame(gameSeedHash, gameId, tooSmallBet, address(usdc), player1, deadline);

        vm.startPrank(player1);
        usdc.approve(address(casino), tooSmallBet);

        vm.expectRevert(CashCow.InvalidBet.selector);
        casino.createGame(gameSeedHash, gameId, tooSmallBet, address(usdc), player1, bytes32(0), signature, deadline);
        vm.stopPrank();
    }

    function testLiquidityView() public {
        bytes32 gameId = keccak256("liquidity_test");
        createGame(player1, gameId);

        (uint256 balance, uint256 treasuryAmt, uint256 lockedAmt) = casino.liquidity(address(usdc));
        assertEq(balance, usdc.balanceOf(address(casino)));
        assertEq(treasuryAmt, casino.treasury(address(usdc)));
        assertEq(lockedAmt, casino.locked(address(usdc)));
        assertEq(lockedAmt, BET_AMOUNT);
    }

    // ========== ERROR CASES ==========

    function testCannotCreateDuplicateGame() public {
        bytes32 gameId = keccak256("duplicate_test");
        createGame(player1, gameId);

        bytes32 gameSeedHash = keccak256(bytes("test_seed"));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = signCreateGame(gameSeedHash, gameId, BET_AMOUNT, address(usdc), player1, deadline);

        vm.startPrank(player1);
        usdc.approve(address(casino), BET_AMOUNT);

        vm.expectRevert(CashCow.GameAlreadyExists.selector);
        casino.createGame(gameSeedHash, gameId, BET_AMOUNT, address(usdc), player1, bytes32(0), signature, deadline);
        vm.stopPrank();
    }

    function testCannotCashoutTwice() public {
        bytes32 gameId = keccak256("double_cashout");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = signCashout("test_seed", gameId, PAYOUT_AMOUNT, address(usdc), player1, deadline);

        vm.prank(player1);
        casino.cashOut(gameId, PAYOUT_AMOUNT, "test_seed", deadline, signature);

        // Second attempt must revert
        CashCow.Game memory g = casino.getGameDetails(gameId);
        bytes memory sig2 = signCashout(g.gameSeed, gameId, PAYOUT_AMOUNT, address(usdc), player1, deadline);

        vm.prank(player1);
        vm.expectRevert(CashCow.GameNotActive.selector);
        casino.cashOut(gameId, PAYOUT_AMOUNT, g.gameSeed, deadline, sig2);
    }

    /// @notice expires in cashOut
    function testCashOutExpiredSignature() public {
        bytes32 gameId = keccak256("expired_cashout");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory signature = signCashout("test_seed", gameId, PAYOUT_AMOUNT, address(usdc), player1, deadline);

        vm.prank(player1);
        vm.expectRevert(CashCow.SignatureExpired.selector);
        casino.cashOut(gameId, PAYOUT_AMOUNT, "test_seed", deadline, signature);
    }

    /// @notice expires in markGameAsLost
    function testMarkGameAsLostExpiredSignature() public {
        bytes32 gameId = keccak256("expired_loss");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory signature = signLoss("test_seed", gameId, BET_AMOUNT, address(usdc), player1, deadline);

        vm.prank(player1);
        vm.expectRevert(CashCow.SignatureExpired.selector);
        casino.markGameAsLost(gameId, "test_seed", deadline, signature);
    }

    /// @notice wrong‐seed path in markGameAsLost
    function testMarkGameAsLostInvalidSeedReverts() public {
        bytes32 gameId = keccak256("invalid_seed_loss");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp + 1 hours;
        // using a bad seed will hit the InvalidSeed check
        bytes memory signature = signLoss("wrong_seed", gameId, BET_AMOUNT, address(usdc), player1, deadline);

        vm.prank(player1);
        vm.expectRevert(CashCow.InvalidSeed.selector);
        casino.markGameAsLost(gameId, "wrong_seed", deadline, signature);
    }

    /// @notice calling markGameAsLost twice → GameNotActive
    function testMarkGameAsLostNonActiveReverts() public {
        bytes32 gameId = keccak256("non_active_loss");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = signLoss("test_seed", gameId, BET_AMOUNT, address(usdc), player1, deadline);

        // first mark as lost
        vm.prank(player2);
        casino.markGameAsLost(gameId, "test_seed", deadline, signature);

        // second attempt should revert GameNotActive
        vm.prank(player2);
        vm.expectRevert(CashCow.GameNotActive.selector);
        casino.markGameAsLost(gameId, "test_seed", deadline, signature);
    }

    function testInvalidSeed() public {
        bytes32 gameId = keccak256("seed_test");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = signCashout("wrong_seed", gameId, PAYOUT_AMOUNT, address(usdc), player1, deadline);

        vm.expectRevert(CashCow.InvalidSeed.selector);
        vm.prank(player1);
        casino.cashOut(gameId, PAYOUT_AMOUNT, "wrong_seed", deadline, signature);
    }

    function testExpiredSignature() public {
        bytes32 gameId = keccak256("expired_test");
        bytes32 gameSeedHash = keccak256(bytes("test_seed"));
        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory signature = signCreateGame(gameSeedHash, gameId, BET_AMOUNT, address(usdc), player1, deadline);

        vm.startPrank(player1);
        usdc.approve(address(casino), BET_AMOUNT);
        vm.expectRevert(CashCow.SignatureExpired.selector);
        casino.createGame(gameSeedHash, gameId, BET_AMOUNT, address(usdc), player1, bytes32(0), signature, deadline);
        vm.stopPrank();
    }

    // ========== ACCESS CONTROL TESTS ==========

    function testOnlyOwnerCanAddToTreasury() public {
        vm.prank(player1);
        vm.expectRevert(); // Ownable: caller is not the owner
        casino.addToTreasury(1000e6, address(usdc));
    }

    function testOnlyOwnerCanRemoveFromTreasury() public {
        vm.prank(player1);
        vm.expectRevert(); // Ownable: caller is not the owner
        casino.removeFromTreasury(1000e6, address(usdc), player1);
    }

    function testOnlyOwnerCanUpdateMinBet() public {
        vm.prank(player1);
        vm.expectRevert(); // Ownable: caller is not the owner
        casino.updateBetLimits(address(usdc), 50e6, 100e6);
    }

    function testTreasuryWithdrawalRespectingLockedFunds() public {
        bytes32 gameId = keccak256("lock_test");
        createGame(player1, gameId);

        uint256 treasuryAmt = casino.treasury(address(usdc));
        uint256 lockedAmt = casino.locked(address(usdc));
        uint256 available = treasuryAmt - lockedAmt;

        vm.startPrank(owner);
        vm.expectRevert(CashCow.InsufficientTreasuryFunds.selector);
        casino.removeFromTreasury(available + 1, address(usdc), owner);

        // Withdraw exactly the available portion
        casino.removeFromTreasury(available, address(usdc), owner);
        vm.stopPrank();

        assertEq(casino.treasury(address(usdc)), lockedAmt);
    }

    // ========== INTEGRATION TEST ==========

    function testFullGameLifecycleWithLocking() public {
        uint256 initialTreasury = casino.treasury(address(usdc));

        bytes32 game1 = keccak256("game1");
        bytes32 game2 = keccak256("game2");
        bytes32 game3 = keccak256("game3");

        createGame(player1, game1);
        createGame(player2, game2);
        createGame(player1, game3);

        // All three locked
        assertEq(casino.locked(address(usdc)), BET_AMOUNT * 3);

        uint256 deadline = block.timestamp + 1 hours;

        // 1: player1 wins
        bytes memory sig1 = signCashout("test_seed", game1, 150e6, address(usdc), player1, deadline);
        vm.prank(player2);
        casino.cashOut(game1, 150e6, "test_seed", deadline, sig1);

        assertEq(casino.locked(address(usdc)), BET_AMOUNT * 2);
        assertEq(casino.treasury(address(usdc)), initialTreasury - 50e6);

        // 2: player2 loses
        bytes memory sig2 = signLoss("test_seed", game2, BET_AMOUNT, address(usdc), player2, deadline);
        vm.prank(player1);
        casino.markGameAsLost(game2, "test_seed", deadline, sig2);

        assertEq(casino.locked(address(usdc)), BET_AMOUNT);
        assertEq(casino.treasury(address(usdc)), initialTreasury - 50e6 + BET_AMOUNT);

        // 3: player1 wins exactly bet
        bytes memory sig3 = signCashout("test_seed", game3, BET_AMOUNT, address(usdc), player1, deadline);
        vm.prank(player2);
        casino.cashOut(game3, BET_AMOUNT, "test_seed", deadline, sig3);

        assertEq(casino.locked(address(usdc)), 0);
        // No further treasury change
        assertEq(casino.treasury(address(usdc)), initialTreasury - 50e6 + BET_AMOUNT);
    }

    // ========== EDGE CASES ==========

    function testGetNonExistentGame() public {
        bytes32 nonExist = keccak256("non_existent");
        vm.expectRevert(CashCow.GameDoesNotExist.selector);
        casino.getGameDetails(nonExist);
    }

    function testZeroPayoutReverts() public {
        bytes32 gameId = keccak256("zero_payout");
        createGame(player1, gameId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = signCashout("final_seed", gameId, 0, address(usdc), player1, deadline);

        vm.expectRevert(CashCow.InvalidPayout.selector);
        vm.prank(player1);
        casino.cashOut(gameId, 0, "final_seed", deadline, signature);
    }

    function testPayoutLessThanBet() public {
        bytes32 gameId = keccak256("small_payout");
        createGame(player1, gameId);

        uint256 smallPayout = BET_AMOUNT / 2;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 treasuryBefore = casino.treasury(address(usdc));

        bytes memory signature = signCashout("test_seed", gameId, smallPayout, address(usdc), player1, deadline);

        vm.prank(player1);
        casino.cashOut(gameId, smallPayout, "test_seed", deadline, signature);

        // Because payout < bet, treasury stays the same
        assertEq(casino.treasury(address(usdc)), treasuryBefore);
    }

    function testVerifyFunction() public {
        string memory seed = "test_seed";
        bytes32 correctHash = keccak256(bytes(seed));
        bytes32 incorrectHash = keccak256(bytes("wrong_seed"));

        assertTrue(casino.verify(seed, correctHash));
        assertFalse(casino.verify(seed, incorrectHash));
    }

    // ========== NEGATIVE CREATE GAME BRANCHES ==========

    function testCreateGameZeroBetReverts() public {
        bytes32 gameId = keccak256("zero_bet");
        bytes32 seedHash = keccak256(bytes("test_seed"));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory badSig = signCreateGame(seedHash, gameId, 0, address(usdc), player1, deadline);

        vm.startPrank(player1);
        usdc.approve(address(casino), 0);
        vm.expectRevert(CashCow.InvalidBet.selector);
        casino.createGame(seedHash, gameId, 0, address(usdc), player1, bytes32(0), badSig, deadline);
        vm.stopPrank();
    }

    function testCreateGameInvalidSignatureReverts() public {
        bytes32 gameId = keccak256("bad_sig");
        bytes32 seedHash = keccak256(bytes("test_seed"));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory junk = new bytes(65);

        vm.startPrank(player1);
        usdc.approve(address(casino), BET_AMOUNT);
        vm.expectRevert(CashCow.InvalidServerSignature.selector);
        casino.createGame(seedHash, gameId, BET_AMOUNT, address(usdc), player1, bytes32(0), junk, deadline);
        vm.stopPrank();
    }

    // ========== CASHOUT BRANCHES ==========

    function testCashOutNonexistentReverts() public {
        bytes32 gameId = keccak256("no_game");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory junk = new bytes(65);

        vm.prank(player1);
        vm.expectRevert(CashCow.GameDoesNotExist.selector);
        casino.cashOut(gameId, PAYOUT_AMOUNT, "test_seed", deadline, junk);
    }

    function testCashOutInvalidSignatureReverts() public {
        bytes32 gameId = keccak256("game1");
        createGame(player1, gameId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory junk = new bytes(65);

        vm.prank(player1);
        vm.expectRevert(CashCow.InvalidServerSignature.selector);
        casino.cashOut(gameId, PAYOUT_AMOUNT, "test_seed", deadline, junk);
    }

    function testCashOutInsufficientTreasuryFundsReverts() public {
        // 1) Set up a new game and lock up the bet
        bytes32 gameId = keccak256("game1");
        createGame(player1, gameId);

        // 2) Drain only the AVAILABLE treasury (treasury - locked)
        uint256 available = casino.treasury(address(usdc)) - casino.locked(address(usdc));
        vm.startPrank(owner);
        casino.removeFromTreasury(available, address(usdc), owner);
        vm.stopPrank();
        // now: treasury == locked == BET_AMOUNT

        // 3) Try to cash out so that excess payout > treasury
        uint256 deadline = block.timestamp + 1 hours;
        // bigPayout such that (bigPayout - BET_AMOUNT) > treasury
        uint256 bigPayout = BET_AMOUNT + casino.treasury(address(usdc)) + 1;

        bytes memory signature = signCashout("test_seed", gameId, bigPayout, address(usdc), player1, deadline);

        // 4) Expect the INSufficientTreasuryFunds revert inside cashOut
        vm.prank(player1);
        vm.expectRevert(CashCow.InsufficientTreasuryFunds.selector);
        casino.cashOut(gameId, bigPayout, "test_seed", deadline, signature);
    }

    // ========== MARK AS LOST BRANCHES ==========

    function testMarkGameAsLostNonexistentReverts() public {
        bytes32 gameId = keccak256("no_game");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory junk = new bytes(65);

        vm.prank(player1);
        vm.expectRevert(CashCow.GameDoesNotExist.selector);
        casino.markGameAsLost(gameId, "test_seed", deadline, junk);
    }

    function testMarkGameAsLostInvalidSignatureReverts() public {
        bytes32 gameId = keccak256("game1");
        createGame(player1, gameId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory junk = new bytes(65);

        vm.prank(player2);
        vm.expectRevert(CashCow.InvalidServerSignature.selector);
        casino.markGameAsLost(gameId, "test_seed", deadline, junk);
    }

    // ========== EXPIRE GAME BRANCHES ==========

    function testExpireGameTooEarlyReverts() public {
        bytes32 gameId = keccak256("to_soon");
        createGame(player1, gameId);

        vm.expectRevert(CashCow.GameStillActive.selector);
        casino.expireGame(gameId);
    }

    function testExpireGameSuccess() public {
        bytes32 gameId = keccak256("will_expire");
        createGame(player1, gameId);

        // fast‑forward past 6 hours
        vm.warp(block.timestamp + casino.GAME_EXPIRY() + 1);

        vm.expectEmit(true, true, false, true);
        emit GameExpired(gameId, player1);
        casino.expireGame(gameId);

        CashCow.Game memory g = casino.getGameDetails(gameId);
        assertEq(uint256(g.status), uint256(CashCow.GameStatus.EXPIRED));
        // locked released, treasury recovers the bet
        assertEq(casino.locked(address(usdc)), 0);
        assertEq(casino.treasury(address(usdc)), INITIAL_TREASURY + BET_AMOUNT);
    }

    function testExpireGameNonActiveReverts() public {
        bytes32 gameId = keccak256("already_resolved");
        createGame(player1, gameId);

        // resolve it
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signCashout("test_seed", gameId, BET_AMOUNT, address(usdc), player1, deadline);
        vm.prank(player2);
        casino.cashOut(gameId, BET_AMOUNT, "test_seed", deadline, sig);

        vm.expectRevert(CashCow.GameNotActive.selector);
        casino.expireGame(gameId);
    }

    // ========== ADMIN FUNCTIONS ==========

    function testUpdateMinBetAsOwner() public {
        address token = address(usdc);
        uint256 newMinBet = 50e6;
        uint256 newMaxBet = 100e6;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit BetLimitsUpdated(token, newMinBet, newMaxBet);
        casino.updateBetLimits(token, newMinBet, newMaxBet);
        (uint256 minBet, uint256 maxBet) = casino.betLimits(token);
        assertEq(minBet, newMinBet);
        assertEq(maxBet, newMaxBet);

        vm.prank(owner);
        vm.expectRevert(CashCow.InvalidBetLimits.selector);
        casino.updateBetLimits(token, newMaxBet, newMinBet);
    }

    function testAddToTreasuryAsOwner() public {
        uint256 deposit = 500e6;
        usdc.mint(owner, deposit);

        vm.startPrank(owner);
        usdc.approve(address(casino), deposit);
        vm.expectEmit(false, false, false, true);
        emit TreasuryDeposit(deposit, address(usdc));
        casino.addToTreasury(deposit, address(usdc));
        vm.stopPrank();

        assertEq(casino.treasury(address(usdc)), INITIAL_TREASURY + deposit);
    }
}
