// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IMsgSender } from "./interfaces/IMsgSender.sol";

/// @notice Per-pool configuration and transient anti-MEV state for `CustomFeeAntiMevHook`.
/// @dev Mappings inside this struct are not directly returnable; use the hook's view helpers.
struct PoolState {
    /// @notice Buy fee in LP fee units (0–1_000_000 = 0–100%).
    uint24 buyFeeBps;
    uint24 sellFeeBps;
    /// @notice Token that the hook considers the "project token" for this pool (the non-native side).
    /// @dev Set during `afterInitialize` for TOKEN/ETH or TOKEN/WETH pools.
    address targetToken;
    /// @notice Whether cooldown / one-trade-per-block protections are enabled.
    bool isProtected;
    /// @notice Minimum time between trades for the same swapper (0 disables this behaviour).
    uint64 cooldownSeconds;
    /// @notice Maximum allowed sell amount (0 disables this behaviour).
    uint256 maxSellAmount;
    /// @notice Addresses blocked from swapping through this hook for this pool.
    mapping(address => bool) isBlacklisted;
    /// @notice Last block a swapper traded in for this pool.
    mapping(address => uint64) lastTradeBlock;
    /// @notice Last timestamp a swapper traded at for this pool.
    mapping(address => uint64) lastTradeTimestamp;
    /// @notice Routers allowed to resolve the "real" user via `IMsgSender(msgSender)`.
    mapping(address router => bool approved) verifiedRouters;
}

/// @title CustomFeeAntiMevHook
/// @notice Uniswap v4 hook that overrides LP fee per swap direction and optionally applies anti-MEV protections.
/// @dev Fee override + protections are only applied for TOKEN/ETH or TOKEN/WETH pools (exactly one side is native/wrapped-native).
contract CustomFeeAntiMevHook is BaseHook {
    /// @notice Default buy/sell fee applied on pool initialization.
    uint24 public constant DEFAULT_FEE_BPS = 3000;

    /// @notice Native currency sentinel used by v4 (i.e. `address(0)`).
    address public constant ADDRESS_ZERO = address(0);
    /// @notice Wrapped native token (WETH, WBNB, etc) used for pool eligibility checks.
    address public immutable wrappedNative;

    /// @dev Per-pool state, keyed by `PoolId`.
    mapping(PoolId poolId => PoolState poolState) internal poolStates;

    /// @notice Emitted when a pool's buy fee is updated.
    event BuyFeeUpdated(PoolId indexed poolId, uint24 oldFeeBps, uint24 newFeeBps);
    /// @notice Emitted when a pool's sell fee is updated.
    event SellFeeUpdated(PoolId indexed poolId, uint24 oldFeeBps, uint24 newFeeBps);
    /// @notice Emitted when a pool's protection flag is toggled.
    event ProtectionUpdated(PoolId indexed poolId, bool isProtected);
    /// @notice Emitted when a pool's cooldown seconds is updated.
    event CooldownSecondsUpdated(PoolId indexed poolId, uint64 oldCooldownSeconds, uint64 newCooldownSeconds);
    /// @notice Emitted when a pool's max sell amount is updated.
    event MaxSellAmountUpdated(PoolId indexed poolId, uint256 oldMaxSellAmount, uint256 newMaxSellAmount);
    /// @notice Emitted when a pool's blacklist is updated.
    event BlacklistUpdated(PoolId indexed poolId, address indexed user, bool blocked);
    /// @notice Emitted when a router is (un)verified for a pool.
    event VerifiedRouterUpdated(PoolId indexed poolId, address indexed router, bool approved);

    /// @notice Thrown when a configured fee exceeds `LPFeeLibrary.MAX_LP_FEE`.
    error FeeTooHigh();
    /// @notice Thrown when the resolved swapper is blacklisted for the pool.
    error Blacklisted();
    /// @notice Thrown when a verified router does not implement `IMsgSender`.
    error RouterDoesNotImplementMsgSender();
    /// @notice Thrown when the pool cooldown is active for the swapper.
    error CooldownActive();
    /// @notice Thrown when the swapper already traded in the current block.
    error OneTradePerBlock();
    /// @notice Thrown when a sell exceeds the configured max sell amount.
    error MaxSellExceeded();
    /// @notice Thrown when a token address is zero in owner checks.
    error TokenAddressZero();
    /// @notice Thrown when `Ownable(token).owner()` cannot be queried.
    error TokenOwnerQueryFailed(address token);
    /// @notice Thrown when the caller is not the token owner (EOA or contract).
    error NotTokenOwner(address token, address tokenOwner, address caller);
    /// @notice Thrown when the pool is not TOKEN/ETH or TOKEN/WETH.
    error UnsupportedPool();

    /// @dev Restricts mutations to the token owner. Accepts a direct call from the owner
    modifier onlyTokenOwner(address token) {
        if (token == ADDRESS_ZERO) revert TokenAddressZero();
        (bool ok, address tokenOwner) = _tryTokenOwner(token);
        if (!ok) revert TokenOwnerQueryFailed(token);
        if (tokenOwner != msg.sender) revert NotTokenOwner(token, tokenOwner, msg.sender);
        _;
    }

    /// @param _poolManager Uniswap v4 `PoolManager`.
    /// @param _wrappedNative Wrapped native token address used to detect TOKEN/WETH pools.
    constructor(IPoolManager _poolManager, address _wrappedNative) BaseHook(_poolManager) {
        wrappedNative = _wrappedNative;
    }

    /// @notice Sets both buy and sell fees for a pool.
    /// @dev Caller must be the TOKEN owner (for TOKEN/ETH or TOKEN/WETH pools).
    function setFees(
        PoolKey calldata key,
        uint24 _buyFeeBps,
        uint24 _sellFeeBps
    )
        external
        onlyTokenOwner(_poolToken(key))
    {
        _setBuyFeeBps(key, _buyFeeBps);
        _setSellFeeBps(key, _sellFeeBps);
    }

    /// @notice Sets the buy fee for a pool.
    function setBuyFeeBps(PoolKey calldata key, uint24 _buyFeeBps) external onlyTokenOwner(_poolToken(key)) {
        _setBuyFeeBps(key, _buyFeeBps);
    }

    /// @notice Sets the sell fee for a pool.
    function setSellFeeBps(PoolKey calldata key, uint24 _sellFeeBps) external onlyTokenOwner(_poolToken(key)) {
        _setSellFeeBps(key, _sellFeeBps);
    }

    /// @notice Enables anti-MEV protections for a pool.
    function protect(PoolKey calldata key) external onlyTokenOwner(_poolToken(key)) {
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        if (!state.isProtected) {
            state.isProtected = true;
            emit ProtectionUpdated(poolId, true);
        }
    }

    /// @notice Disables anti-MEV protections for a pool.
    function unprotect(PoolKey calldata key) external onlyTokenOwner(_poolToken(key)) {
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        if (state.isProtected) {
            state.isProtected = false;
            emit ProtectionUpdated(poolId, false);
        }
    }

    /// @notice Sets the cooldown seconds for a pool.
    function setCooldownSeconds(
        PoolKey calldata key,
        uint64 _cooldownSeconds
    )
        external
        onlyTokenOwner(_poolToken(key))
    {
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        uint64 old = state.cooldownSeconds;
        state.cooldownSeconds = _cooldownSeconds;
        emit CooldownSecondsUpdated(poolId, old, _cooldownSeconds);
    }

    /// @notice Sets the maximum sell amount for a pool.
    function setMaxSellAmount(PoolKey calldata key, uint256 _maxSellAmount) external onlyTokenOwner(_poolToken(key)) {
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        uint256 old = state.maxSellAmount;
        state.maxSellAmount = _maxSellAmount;
        emit MaxSellAmountUpdated(poolId, old, _maxSellAmount);
    }

    /// @notice Blacklists or unblacklists `user` for a pool.
    function setBlacklist(PoolKey calldata key, address user, bool blocked) external onlyTokenOwner(_poolToken(key)) {
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        state.isBlacklisted[user] = blocked;
        emit BlacklistUpdated(poolId, user, blocked);
    }

    /// @notice (Un)verifies a router for a pool.
    /// @dev When verified, the hook will attempt to resolve the actual user via `IMsgSender(router).msgSender()`.
    function setVerifiedRouter(
        PoolKey calldata key,
        address router,
        bool approved
    )
        external
        onlyTokenOwner(_poolToken(key))
    {
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        state.verifiedRouters[router] = approved;
        emit VerifiedRouterUpdated(poolId, router, approved);
    }

    /// @notice Returns the configured pool parameters (excluding mapping members).
    /// @param key Pool key.
    function getPoolState(PoolKey calldata key)
        external
        view
        returns (
            uint24 buyFeeBps,
            uint24 sellFeeBps,
            address targetToken,
            bool isProtected,
            uint64 cooldownSeconds,
            uint256 maxSellAmount
        )
    {
        (, PoolState storage state) = _stateForKey(key);
        return (
            state.buyFeeBps,
            state.sellFeeBps,
            state.targetToken,
            state.isProtected,
            state.cooldownSeconds,
            state.maxSellAmount
        );
    }

    /// @notice Returns whether `user` is blacklisted for `key`.
    function isPoolBlacklisted(PoolKey calldata key, address user) external view returns (bool) {
        return poolStates[_toPoolId(key)].isBlacklisted[user];
    }

    /// @notice Returns last trade block and timestamp for `user` in `key`.
    function getPoolLastTrade(
        PoolKey calldata key,
        address user
    )
        external
        view
        returns (uint64 lastBlock, uint64 lastTimestamp)
    {
        PoolState storage state = poolStates[_toPoolId(key)];
        return (state.lastTradeBlock[user], state.lastTradeTimestamp[user]);
    }

    /// @notice Declares this hook's permissions.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Internal setter used by external setters.
    function _setBuyFeeBps(PoolKey calldata key, uint24 _buyFeeBps) internal {
        if (_buyFeeBps > LPFeeLibrary.MAX_LP_FEE) revert FeeTooHigh();
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        uint24 old = state.buyFeeBps;
        state.buyFeeBps = _buyFeeBps;
        emit BuyFeeUpdated(poolId, old, _buyFeeBps);
    }

    /// @dev Internal setter used by external setters.
    function _setSellFeeBps(PoolKey calldata key, uint24 _sellFeeBps) internal {
        if (_sellFeeBps > LPFeeLibrary.MAX_LP_FEE) revert FeeTooHigh();
        (PoolId poolId, PoolState storage state) = _stateForKey(key);
        uint24 old = state.sellFeeBps;
        state.sellFeeBps = _sellFeeBps;
        emit SellFeeUpdated(poolId, old, _sellFeeBps);
    }

    /// @dev After-initialize hook used to set per-pool default fees.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        // Only initialize defaults for eligible pools (TOKEN/ETH or TOKEN/WETH).
        bool c0NativeOrWrapped = _isNativeOrWrapped(key.currency0);
        bool c1NativeOrWrapped = _isNativeOrWrapped(key.currency1);

        (, PoolState storage state) = _stateForKey(key);

        // Cache the target token (non-native side) for the pool to avoid recomputing on every swap
        // and disable hook behaviour in case no suitable token was found
        if (c0NativeOrWrapped != c1NativeOrWrapped) {
            address candidate = c0NativeOrWrapped ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
            (bool ok, address tokenOwner) = _tryTokenOwner(candidate);
            if (ok && tokenOwner != ADDRESS_ZERO) {
                state.targetToken = candidate;
            }
        }

        _setBuyFeeBps(key, DEFAULT_FEE_BPS);
        _setSellFeeBps(key, DEFAULT_FEE_BPS);

        return BaseHook.afterInitialize.selector;
    }

    /// @dev Applies per-swapper protection checks and updates last-trade tracking.
    function _applyProtection(PoolState storage state, address swapper) internal {
        if (!state.isProtected) return;

        if (
            state.cooldownSeconds != 0 && state.lastTradeTimestamp[swapper] != 0
                && block.timestamp < state.lastTradeTimestamp[swapper] + state.cooldownSeconds
        ) {
            revert CooldownActive();
        }

        if (state.lastTradeBlock[swapper] == block.number) revert OneTradePerBlock();

        state.lastTradeTimestamp[swapper] = uint64(block.timestamp);
        state.lastTradeBlock[swapper] = uint64(block.number);
    }

    /// @dev Before-swap hook:
    /// - no-ops unless the pool is TOKEN/ETH or TOKEN/WETH,
    /// - resolves swapper via verified routers,
    /// - enforces blacklist and optional anti-MEV protection,
    /// - returns an overridden LP fee when configured.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    )
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24 fee)
    {
        (, PoolState storage state) = _stateForKey(key);

        // If targetToken isn't initialized, only apply the default fee.
        if (state.targetToken == ADDRESS_ZERO) {
            fee = DEFAULT_FEE_BPS | LPFeeLibrary.OVERRIDE_FEE_FLAG;
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), fee);
        }

        address swapper = state.verifiedRouters[sender] ? _getSwapper(sender) : sender;
        if (state.isBlacklisted[swapper]) revert Blacklisted();

        _applyProtection(state, swapper);

        bool isSell = _isSell(key, params.zeroForOne, state.targetToken);
        if (isSell) _checkMaxSell(state, _abs(params.amountSpecified));

        fee = (isSell ? state.sellFeeBps : state.buyFeeBps) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), fee);
    }

    /// @dev Resolves the swapper address for verified routers using `IMsgSender`.
    function _getSwapper(address sender) internal view returns (address swapper) {
        try IMsgSender(sender).msgSender() returns (address user) {
            return user;
        } catch {
            revert RouterDoesNotImplementMsgSender();
        }
    }

    /// @dev Attempts to read the token owner via Ownable, returning success + owner.
    function _tryTokenOwner(address token) internal view returns (bool ok, address tokenOwner) {
        try Ownable(token).owner() returns (address owner) {
            return (true, owner);
        } catch {
            return (false, ADDRESS_ZERO);
        }
    }

    /// @dev Reverts if a sell exceeds `state.maxSellAmount` (when enabled).
    function _checkMaxSell(PoolState storage state, uint256 amountInOrOut) internal view {
        if (state.maxSellAmount != 0 && amountInOrOut > state.maxSellAmount) revert MaxSellExceeded();
    }

    /// @dev Returns true if `currency` is native (`address(0)`) or the configured wrapped native.
    function _isNativeOrWrapped(Currency currency) internal view returns (bool) {
        address currencyAddress = Currency.unwrap(currency);
        return currencyAddress == ADDRESS_ZERO || currencyAddress == wrappedNative;
    }

    /// @param key Target pool key
    /// @dev Given `key` is checked if it can be used inside this hook
    ///      Will NOT revert only for 'TOKEN / ETH' || 'TOKEN / WETH' pools
    /// @return token Address of taxed token which is used to define sell direction
    function _poolToken(PoolKey calldata key) internal view returns (address token) {
        PoolState storage state = poolStates[_toPoolId(key)];
        return state.targetToken;
    }

    /// @dev Returns the storage state for a pool key.
    function _stateForKey(PoolKey calldata key) internal view returns (PoolId poolId, PoolState storage state) {
        poolId = _toPoolId(key);
        state = poolStates[poolId];
    }

    /// @dev Absolute value for signed integers.
    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @dev Returns true if the swap is a sell of `taxToken` (i.e. `taxToken` -> native/wrapped-native).
    function _isSell(PoolKey calldata key, bool zeroForOne, address taxToken) internal pure returns (bool) {
        if (taxToken == Currency.unwrap(key.currency0)) {
            return zeroForOne; // token0 -> token1
        }
        if (taxToken == Currency.unwrap(key.currency1)) {
            return !zeroForOne; // token1 -> token0
        }
        return false;
    }

    /// @dev Computes the pool id for a calldata key.
    function _toPoolId(PoolKey calldata key) internal pure returns (PoolId) {
        PoolKey memory keyMem = key;
        return keyMem.toId();
    }
}
