// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CashCow is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    // ===================
    // State Variables
    // ===================

    /// @notice Time after which games will expire
    uint256 public constant GAME_EXPIRY = 6 hours;

    /// @notice Game status enum
    enum GameStatus {
        ACTIVE,
        WON,
        LOST,
        EXPIRED
    }

    /// @notice Game data structure
    struct Game {
        bytes32 gameSeedHash; // Hash of the seed + algoVersion
        bytes32 gameId; // the game ID from the backend
        bytes32 extra; // Store extra params
        uint256 createdAt; // Block timestamp when game was created
        uint256 betAmount; // Original bet amount
        uint256 payoutAmount; // Final payout amount (0 if lost)
        address betToken; // Token used to place bet
        address player; // Player's wallet address
        GameStatus status; // Current game status
        string gameSeed; // Seed used to generate the game state
    }

    /// @notice Mapping from on-chain game ID to Game data
    mapping(bytes32 => Game) public games;

    /// @notice Treasury token balances
    mapping(address => uint256) public treasury;

    /// @notice Locked token balances
    mapping(address => uint256) public locked;

    /// @notice Minimum bet per token
    mapping(address => uint256) public minBets;

    // ===================
    // Events
    // ===================

    /// @notice Emitted when a new game is created
    // @dev Keep seed hash in event for listener correlation
    event GameCreated(
        bytes32 indexed gameId,
        address indexed player,
        uint256 betAmount,
        address indexed betToken,
        bytes32 gameSeedHash
    );

    /// @notice Emitted when a game status is updated
    event GameWon(bytes32 indexed gameId, address indexed player, uint256 amount, address indexed token);
    event GameLost(bytes32 indexed gameId, address indexed player);
    event GameExpired(bytes32 indexed gameId, address indexed player);

    /// @notice Min bets updated
    event MinBetUpdated(address indexed token, uint256 minBet);

    /// @notice Treasury events
    event TreasuryDeposit(uint256 amount, address indexed token);
    event TreasuryWithdrawal(uint256 amount, address indexed token);

    // ===================
    // Errors
    // ===================

    /// @notice Error when game already exists
    error GameAlreadyExists();

    /// @notice Error when game doesn't exist
    error GameDoesNotExist();

    /// @notice Error when caller is not the player
    error NotGamePlayer();

    /// @notice Error when game is not in active status
    error GameNotActive();

    /// @notice Error game is still active
    error GameStillActive();

    /// @notice Error when the bet is invalid (null or too low)
    error InvalidBet();

    /// @notice Error if the payout amount is null
    error InvalidPayout();

    /// @notice Error when server signature is invalid or doesn't match expected signer
    error InvalidServerSignature();

    /// @notice Not enough funds in the treasury to play
    error InsufficientFunds();

    /// @notice Not enough funds in the treasury to withdraw
    error InsufficientTreasuryFunds();

    /// @notice Signature has expired
    error SignatureExpired();

    /// @notice Provided game seed does not match on-chain game seed hash
    error InvalidSeed();

    // ===================
    // Constructor
    // ===================

    /**
     * @dev Initializer sets the contract owner and initial server signer address
     * @param _owner The contract admin
     */
    constructor(address _owner) Ownable(_owner) EIP712("CashCow", "1") {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert SignatureExpired();
        _;
    }

    // ===================
    // External Functions
    // ===================

    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    bytes32 public constant CREATE_TYPEHASH = keccak256(
        "Game(bytes32 gameSeedHash, bytes32 gameId, uint256 betAmount, address betToken, address player, uint256 deadline)"
    );

    bytes32 public constant CASHOUT_TYPEHASH = keccak256(
        "Game(string gameSeed, bytes32 gameId, uint256 payoutAmount, address betToken, address player, uint256 deadline)"
    );

    bytes32 public constant LOSS_TYPEHASH = keccak256(
        "Game(string gameSeed, bytes32 gameId, uint256 betAmount, address betToken, address player, uint256 deadline)"
    );

    function hashCreateGame(
        bytes32 gameSeedHash,
        bytes32 gameId,
        uint256 betAmount,
        address betToken,
        address player,
        uint256 deadline
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(CREATE_TYPEHASH, gameSeedHash, gameId, betAmount, betToken, player, deadline));
    }

    function hashCashoutGame(
        string calldata gameSeed,
        bytes32 gameId,
        uint256 payoutAmount,
        address betToken,
        address player,
        uint256 deadline
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(CASHOUT_TYPEHASH, keccak256(bytes(gameSeed)), gameId, payoutAmount, betToken, player, deadline)
        );
    }

    function hashGameLoss(
        string calldata gameSeed,
        bytes32 gameId,
        uint256 betAmount,
        address betToken,
        address player,
        uint256 deadline
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(LOSS_TYPEHASH, keccak256(bytes(gameSeed)), gameId, betAmount, betToken, player, deadline)
        );
    }

    function createGame(
        bytes32 gameSeedHash,
        bytes32 gameId,
        uint256 betAmount,
        address betToken,
        address player,
        bytes32 extra,
        bytes calldata serverSignature,
        uint256 deadline
    ) external checkDeadline(deadline) {
        if (betAmount == 0 || betAmount < minBets[betToken]) revert InvalidBet();
        if (treasury[betToken] - locked[betToken] < betAmount) revert InsufficientFunds();
        if (games[gameId].betAmount != 0) revert GameAlreadyExists();

        bytes32 messageHash = hashCreateGame(gameSeedHash, gameId, betAmount, betToken, player, deadline);
        _verifyAnyAdminSignature(messageHash, serverSignature);

        games[gameId] = Game({
            gameSeed: "",
            gameSeedHash: gameSeedHash,
            gameId: gameId,
            createdAt: block.timestamp,
            betAmount: betAmount,
            betToken: betToken,
            player: player,
            status: GameStatus.ACTIVE,
            extra: extra,
            payoutAmount: 0
        });

        locked[betToken] += betAmount;

        IERC20(betToken).safeTransferFrom(msg.sender, address(this), betAmount);

        emit GameCreated(gameId, player, betAmount, betToken, gameSeedHash);
    }

    function cashOut(
        bytes32 gameId,
        uint256 payoutAmount,
        string calldata gameSeed,
        uint256 deadline,
        bytes calldata serverSignature
    ) external checkDeadline(deadline) {
        Game storage game = games[gameId];

        // verify data
        if (game.player == address(0)) revert GameDoesNotExist();
        if (game.status != GameStatus.ACTIVE) revert GameNotActive();
        if (payoutAmount == 0) revert InvalidPayout();
        if (!verify(gameSeed, game.gameSeedHash)) revert InvalidSeed();

        address token = game.betToken;
        uint256 bet = game.betAmount;

        bytes32 messageHash = hashCashoutGame(gameSeed, gameId, payoutAmount, token, game.player, deadline);
        _verifyAnyAdminSignature(messageHash, serverSignature);

        // process payout
        game.status = GameStatus.WON;
        game.payoutAmount = payoutAmount;
        game.gameSeed = gameSeed;

        if (payoutAmount > bet) {
            // check if the treasury can pay
            uint256 paidFromTreasury = payoutAmount - bet;
            if (paidFromTreasury > treasury[token]) revert InsufficientTreasuryFunds();

            treasury[token] -= paidFromTreasury;
        }
        locked[token] -= bet;

        IERC20(token).safeTransfer(game.player, payoutAmount);

        emit GameWon(gameId, game.player, payoutAmount, token);
    }

    function markGameAsLost(bytes32 gameId, string calldata gameSeed, uint256 deadline, bytes calldata serverSignature)
        external
        checkDeadline(deadline)
    {
        Game storage game = games[gameId];
        if (game.player == address(0)) revert GameDoesNotExist();
        if (game.status != GameStatus.ACTIVE) revert GameNotActive();
        if (!verify(gameSeed, game.gameSeedHash)) revert InvalidSeed();

        address token = game.betToken;
        uint256 bet = game.betAmount;

        bytes32 messageHash = hashGameLoss(gameSeed, gameId, bet, token, game.player, deadline);
        _verifyAnyAdminSignature(messageHash, serverSignature);

        game.status = GameStatus.LOST;
        game.gameSeed = gameSeed;

        treasury[token] += bet;
        locked[token] -= bet;

        emit GameLost(gameId, game.player);
    }

    function expireGame(bytes32 gameId) external {
        Game storage game = games[gameId];
        if (game.status != GameStatus.ACTIVE) revert GameNotActive();
        if (block.timestamp < game.createdAt + GAME_EXPIRY) revert GameStillActive();

        address token = game.betToken;
        uint256 bet = game.betAmount;

        game.status = GameStatus.EXPIRED;
        locked[token] -= bet;
        treasury[token] += bet;

        emit GameExpired(gameId, game.player);
    }

    function getGameDetails(bytes32 gameId) external view returns (Game memory) {
        if (games[gameId].player == address(0)) revert GameDoesNotExist();
        return games[gameId];
    }

    function verify(string calldata gameSeed, bytes32 gameSeedHash) public pure returns (bool) {
        return keccak256(bytes(gameSeed)) == gameSeedHash;
    }

    function liquidity(address token) external view returns (uint256, uint256, uint256) {
        return (IERC20(token).balanceOf(address(this)), treasury[token], locked[token]);
    }

    // ===================
    // Admin Functions
    // ===================

    function updateMinBet(address token, uint256 bet) external onlyOwner {
        minBets[token] = bet;
        emit MinBetUpdated(token, bet);
    }

    function addToTreasury(uint256 amount, address token) external onlyOwner {
        treasury[token] += amount;
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);

        emit TreasuryDeposit(amount, token);
    }

    function removeFromTreasury(uint256 amount, address token, address recipient) external onlyOwner {
        if (treasury[token] - locked[token] < amount) revert InsufficientTreasuryFunds();
        treasury[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit TreasuryWithdrawal(amount, token);
    }

    // ===============================
    // Internal Helper Functions
    // ===============================

    function _verifyAnyAdminSignature(bytes32 _hash, bytes calldata _signature) internal view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), _hash));
        if (!SignatureChecker.isValidSignatureNow(owner(), digest, _signature)) revert InvalidServerSignature();
    }
}
