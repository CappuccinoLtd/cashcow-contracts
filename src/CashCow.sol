// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CashCow is Ownable, EIP712 {
    using Strings for uint256;
    using SafeERC20 for IERC20;

    // ===================
    // State Variables
    // ===================

    /// @notice Counter for unique on-chain game IDs
    uint256 public gameCounter;

    /// @notice Mapping from preliminary game ID to on-chain game ID
    mapping(string => uint256) public preliminaryToOnChainId;

    /// @notice Game status enum
    enum GameStatus {
        Active,
        Won,
        Lost
    }

    /// @notice Game data structure
    struct Game {
        uint256 createdAt; // Block timestamp when game was created
        uint256 betAmount; // Original bet amount
        address betToken; // Token used to place bet
        address player; // Player's wallet address
        GameStatus status; // Current game status
        uint256 payoutAmount; // Final payout amount (0 if lost)
        bytes32 gameSeedHash; // Hash of the seed + algoVersion
        string gameSeed; // Seed used to generate the game state
        string algoVersion; // Algorithm version for going from seed to game state
    }

    /// @notice Mapping from on-chain game ID to Game data
    mapping(uint256 => Game) public games;

    /// @notice Treasury token balances
    mapping(address => uint256) public treasury;

    // ===================
    // Events
    // ===================

    /// @notice Emitted when a new game is created
    // @dev Keep seed hash in event for listener correlation
    event GameCreated(
        string preliminaryGameId,
        uint256 indexed onChainGameId,
        address indexed player,
        uint256 betAmount,
        address betToken,
        bytes32 gameSeedHash
    );

    /// @notice Emitted when a payout is sent to a player
    event PayoutSent(uint256 indexed onChainGameId, uint256 amount, address token, address indexed recipient);

    /// @notice Emitted when a game status is updated
    event GameStatusUpdated(uint256 indexed onChainGameId, GameStatus status);

    /// @notice Emitted when funds are deposited directly into the contract
    event DepositReceived(address indexed sender, uint256 amount, address indexed token);

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

    /// @notice Error when payout fails
    error PayoutFailed();

    /// @notice Error when server signature is invalid or doesn't match expected signer
    error InvalidServerSignature();

    /// @notice Not enough funds in the treasury to play
    error InsufficientFunds();

    /// @notice Not enough funds in the treasury to withdraw
    error InsufficientTreasuryFunds();

    /// @notice Signature has expired
    error Expired();

    // ===================
    // Constructor
    // ===================

    /**
     * @dev Initializer sets the contract owner and initial server signer address
     * @param _owner The contract admin
     */
    constructor(address _owner) Ownable(_owner) EIP712("CashCow", "1") {
        gameCounter = 0;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // ===================
    // External Functions
    // ===================

    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    bytes32 public constant CREATE_TYPEHASH = keccak256(
        "Game(string gameId, bytes32 gameSeedHash, string algoVersion, address user, uint256 betAmount, address betToken, uint256 deadline)"
    );

    bytes32 public constant CASHOUT_TYPEHASH =
        keccak256("Game(uint256 onChainGameId, uint256 payoutAmount, string gameSeed, uint256 deadline)");

    bytes32 public constant LOSS_TYPEHASH = keccak256("Game(uint256 onChainGameId, string gameSeed, uint256 deadline)");

    function hashCreateGame(
        string calldata gameId,
        bytes32 gameSeedHash,
        string calldata algoVersion,
        address user,
        uint256 betAmount,
        address betToken,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(CREATE_TYPEHASH, gameId, gameSeedHash, algoVersion, user, betAmount, betToken, deadline)
        );
    }

    function hashCashoutGame(uint256 onChainGameId, uint256 payoutAmount, string calldata gameSeed, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CASHOUT_TYPEHASH, onChainGameId, payoutAmount, gameSeed, deadline));
    }

    function hashLostGame(uint256 onChainGameId, string calldata gameSeed, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(LOSS_TYPEHASH, onChainGameId, gameSeed, deadline));
    }

    /**
     * @notice Creates a new game placeholder on-chain. Requires server signature.
     * Only gameSeedHash is needed for provable fairness.
     * @param preliminaryGameId The preliminary game ID generated by the backend
     * @param gameSeedHash Hash of the actual game seed (used for listener correlation)
     * @param algoVersion The algorithm version for provable fairness
     * @param bet The initial bet
     * @param token The token supplied
     * @param deadline The latest timestamp this signature is valid for
     * @param serverSignature Signature from the server authorizing this game creation
     */
    function createGame(
        string calldata preliminaryGameId,
        bytes32 gameSeedHash,
        string calldata algoVersion,
        uint256 bet,
        address token,
        uint256 deadline,
        bytes calldata serverSignature
    ) external checkDeadline(deadline) {
        {
            if (treasury[token] <= bet) revert InsufficientFunds();
            if (preliminaryToOnChainId[preliminaryGameId] != 0) revert GameAlreadyExists();

            bytes32 messageHash =
                hashCreateGame(preliminaryGameId, gameSeedHash, algoVersion, msg.sender, bet, token, deadline);
            _verifyAnyAdminSignature(messageHash, serverSignature);
        }

        {
            IERC20(token).safeTransferFrom(msg.sender, address(this), bet);

            gameCounter += 1;
            preliminaryToOnChainId[preliminaryGameId] = gameCounter;
            games[gameCounter] = Game({
                player: msg.sender,
                betAmount: bet,
                betToken: token,
                gameSeedHash: gameSeedHash,
                status: GameStatus.Active,
                payoutAmount: 0,
                gameSeed: "",
                algoVersion: algoVersion,
                createdAt: block.timestamp
            });
        }

        emit GameCreated(preliminaryGameId, gameCounter, msg.sender, bet, token, gameSeedHash);
    }

    /**
     * @notice Processes a cash out. Callable by an admin (no signature) or by the player with a valid server signature.
     * @param onChainGameId The on-chain game ID.
     * @param payoutAmount The NET amount to pay out.
     * @param gameSeed The final game seed to store for provable fairness
     * @param deadline The latest timestamp this signature is valid for
     * @param serverSignature Signature from an admin authorizing this cash out (only required if called by player)
     */
    function cashOut(
        uint256 onChainGameId,
        uint256 payoutAmount,
        string calldata gameSeed,
        uint256 deadline,
        bytes calldata serverSignature
    ) external checkDeadline(deadline) {
        Game storage game = games[onChainGameId];

        // verify data
        if (game.player == address(0)) {
            revert GameDoesNotExist();
        }
        if (game.status != GameStatus.Active) {
            revert GameNotActive();
        }
        assert(payoutAmount > 0);

        address playerAddress = game.player;
        if (!_isOwner(msg.sender)) {
            require(msg.sender == playerAddress, "Not authorized");
            bytes32 messageHash = hashCashoutGame(onChainGameId, payoutAmount, gameSeed, deadline);
            _verifyAnyAdminSignature(messageHash, serverSignature);
        }

        // --- EFFECTS (set state before external call) ---
        game.status = GameStatus.Won;
        game.payoutAmount = payoutAmount;
        game.gameSeed = gameSeed; // Store the game seed

        // --- PAYOUT ---
        IERC20(game.betToken).safeTransfer(playerAddress, payoutAmount);

        emit GameStatusUpdated(onChainGameId, GameStatus.Won);
        emit PayoutSent(onChainGameId, payoutAmount, game.betToken, playerAddress);
    }

    /**
     * @notice Mark a game as lost. Callable by an admin (no signature) or by the player with a valid server signature.
     * @param onChainGameId The on-chain game ID
     * @param gameSeed The final game seed to store for provable fairness
     * @param deadline The latest timestamp this signature is valid for
     * @param serverSignature Signature from an admin authorizing this loss (only required if called by player)
     */
    function markGameAsLost(
        uint256 onChainGameId,
        string calldata gameSeed,
        uint256 deadline,
        bytes calldata serverSignature
    ) external checkDeadline(deadline) {
        Game storage game = games[onChainGameId];
        if (game.player == address(0)) {
            revert GameDoesNotExist();
        }
        if (game.status != GameStatus.Active) {
            revert GameNotActive();
        }
        address playerAddress = game.player;

        if (!_isOwner(msg.sender)) {
            require(msg.sender == playerAddress, "Not authorized");
            bytes32 messageHash = hashLostGame(onChainGameId, gameSeed, deadline);
            _verifyAnyAdminSignature(messageHash, serverSignature);
        }

        game.status = GameStatus.Lost;
        game.gameSeed = gameSeed; // Store the game seed

        treasury[game.betToken] += game.betAmount;

        emit GameStatusUpdated(onChainGameId, GameStatus.Lost);
    }

    /**
     * @notice Get details for a specific game
     * @param onChainGameId The on-chain game ID
     * @return Game struct with all game details
     */
    function getGameDetails(uint256 onChainGameId) external view returns (Game memory) {
        if (games[onChainGameId].player == address(0)) {
            revert GameDoesNotExist();
        }
        return games[onChainGameId];
    }

    /**
     * @notice Get on-chain ID from preliminary ID
     * @param preliminaryGameId The preliminary game ID
     * @return onChainGameId The corresponding on-chain game ID (0 if not found)
     */
    function getOnChainGameId(string calldata preliminaryGameId) external view returns (uint256) {
        return preliminaryToOnChainId[preliminaryGameId];
    }

    // ===================
    // Admin Functions
    // ===================

    function addToTreasury(uint256 amount, address token) external onlyOwner {
        treasury[token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function removeFromTreasury(uint256 amount, address token, address recipient) external onlyOwner {
        if (treasury[token] < amount) revert InsufficientTreasuryFunds();
        treasury[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
    }

    // ===============================
    // Internal Helper Functions
    // ===============================

    /**
     * @dev Verifies that the provided signature for the given hash was generated by any admin.
     * Reverts with InvalidServerSignature if verification fails.
     * @param _hash The hash that was signed.
     * @param _signature The signature bytes (expected length 65).
     */
    function _verifyAnyAdminSignature(bytes32 _hash, bytes calldata _signature) internal view {
        if (!SignatureChecker.isValidSignatureNow(owner(), _hash, _signature)) {
            revert InvalidServerSignature();
        }
    }

    function _isOwner(address user) internal view returns (bool) {
        return owner() == user;
    }
}
