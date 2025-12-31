// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Deployers as V4Deployers } from "v4-core/test/utils/Deployers.sol";

import { CustomFeeAntiMevHook } from "../src/CustomFeeAntiMevHook.sol";
import { IMsgSender } from "../src/interfaces/IMsgSender.sol";
import { NonOwnableMintableERC20 } from "./mocks/NonOwnableMintableERC20.sol";
import { OwnableMintableERC20 } from "./mocks/OwnableMintableERC20.sol";

import { HookMiner } from "v4-periphery/src/utils/HookMiner.sol";

import { CustomRevert } from "v4-core/src/libraries/CustomRevert.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { SwapParams } from "v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";

import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import { PoolTestBase } from "v4-core/src/test/PoolTestBase.sol";
import { CurrencySettler } from "v4-core/test/utils/CurrencySettler.sol";

contract MsgSenderPoolSwapTest is PoolTestBase, IMsgSender {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;

    struct CallbackData {
        address sender;
        TestSettings testSettings;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    address private _msgSender;

    constructor(IPoolManager _manager) PoolTestBase(_manager) { }

    function msgSender() external view returns (address) {
        return _msgSender;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    )
        external
        payable
        returns (BalanceDelta delta)
    {
        _msgSender = msg.sender;
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, testSettings, key, params, hookData))), (BalanceDelta)
        );
        _msgSender = address(0);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (,, int256 deltaBefore0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(deltaBefore0 == 0, "deltaBefore0 is not equal to 0");
        require(deltaBefore1 == 0, "deltaBefore1 is not equal to 0");

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (data.params.zeroForOne) {
            if (data.params.amountSpecified < 0) {
                require(deltaAfter0 >= data.params.amountSpecified, "deltaAfter0 < amountSpecified");
                require(delta.amount0() == deltaAfter0, "delta.amount0 != deltaAfter0");
                require(deltaAfter1 >= 0, "deltaAfter1 < 0");
            } else {
                require(deltaAfter0 <= 0, "deltaAfter0 > 0");
                require(delta.amount1() == deltaAfter1, "delta.amount1 != deltaAfter1");
                require(deltaAfter1 <= data.params.amountSpecified, "deltaAfter1 > amountSpecified");
            }
        } else {
            if (data.params.amountSpecified < 0) {
                require(deltaAfter1 >= data.params.amountSpecified, "deltaAfter1 < amountSpecified");
                require(delta.amount1() == deltaAfter1, "delta.amount1 != deltaAfter1");
                require(deltaAfter0 >= 0, "deltaAfter0 < 0");
            } else {
                require(deltaAfter1 <= 0, "deltaAfter1 > 0");
                require(delta.amount0() == deltaAfter0, "delta.amount0 != deltaAfter0");
                require(deltaAfter0 <= data.params.amountSpecified, "deltaAfter0 > amountSpecified");
            }
        }

        if (deltaAfter0 < 0) {
            data.key.currency0.settle(manager, data.sender, uint256(-deltaAfter0), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(manager, data.sender, uint256(-deltaAfter1), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter0 > 0) {
            data.key.currency0.take(manager, data.sender, uint256(deltaAfter0), data.testSettings.takeClaims);
        }
        if (deltaAfter1 > 0) {
            data.key.currency1.take(manager, data.sender, uint256(deltaAfter1), data.testSettings.takeClaims);
        }

        return abi.encode(delta);
    }
}

contract CustomFeeAntiMevHookTest is V4Deployers {
    CustomFeeAntiMevHook hook;
    MsgSenderPoolSwapTest msgSenderSwapRouter;

    OwnableMintableERC20 token;
    IERC20Minimal weth;
    Currency taxToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();

        token = new OwnableMintableERC20("TOKEN", "TOKEN", address(this));
        token.mint(address(this), 2 ** 255);
        token.mint(alice, 1_000_000 ether);
        token.mint(bob, 1_000_000 ether);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];
        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], type(uint256).max);
        }

        Currency wethCurrency = deployMintAndApproveCurrency();
        weth = IERC20Minimal(Currency.unwrap(wethCurrency));

        Currency tokenCurrency = Currency.wrap(address(token));
        taxToken = tokenCurrency;
        (currency0, currency1) = Currency.unwrap(tokenCurrency) < Currency.unwrap(wethCurrency)
            ? (tokenCurrency, wethCurrency)
            : (wethCurrency, tokenCurrency);

        msgSenderSwapRouter = new MsgSenderPoolSwapTest(manager);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(msgSenderSwapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(msgSenderSwapRouter), type(uint256).max);

        // fund alice & bob for swaps (weth only; token minted above)
        weth.transfer(alice, 1_000_000 ether);
        weth.transfer(bob, 1_000_000 ether);

        vm.prank(alice);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(msgSenderSwapRouter), type(uint256).max);
        vm.prank(alice);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(msgSenderSwapRouter), type(uint256).max);

        vm.prank(bob);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(msgSenderSwapRouter), type(uint256).max);
        vm.prank(bob);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(msgSenderSwapRouter), type(uint256).max);
    }

    function _deployHook() internal returns (CustomFeeAntiMevHook deployed) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        bytes memory ctorArgs = abi.encode(manager, address(weth));
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CustomFeeAntiMevHook).creationCode, ctorArgs);

        deployed = new CustomFeeAntiMevHook{ salt: salt }(manager, address(weth));
        assertEq(address(deployed), hookAddr);

        hook = deployed;
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(deployed)));
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function _swapSellExactInput(address swapper, uint256 amountInAbs) internal returns (BalanceDelta) {
        bool zeroForOne = Currency.unwrap(taxToken) == Currency.unwrap(key.currency0);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(amountInAbs), sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(swapper);
        return msgSenderSwapRouter.swap(
            key, params, MsgSenderPoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES
        );
    }

    function _swapBuyExactInput(address swapper, uint256 amountInAbs) internal returns (BalanceDelta) {
        bool zeroForOne = Currency.unwrap(taxToken) != Currency.unwrap(key.currency0);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(amountInAbs), sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(swapper);
        return msgSenderSwapRouter.swap(
            key, params, MsgSenderPoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES
        );
    }

    function _expectBeforeSwapWrappedRevert(bytes4 hookErrorSelector) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(hookErrorSelector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _sellOutput(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(taxToken) == Currency.unwrap(key.currency0) ? delta.amount1() : delta.amount0();
    }

    function _buyOutput(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(taxToken) == Currency.unwrap(key.currency0) ? delta.amount0() : delta.amount1();
    }

    function test_blacklistedSwapper_reverts_whenRouterVerified() public {
        _deployHook();

        hook.setVerifiedRouter(key, address(msgSenderSwapRouter), true);
        hook.setBlacklist(key, alice, true);

        _expectBeforeSwapWrappedRevert(CustomFeeAntiMevHook.Blacklisted.selector);
        _swapSellExactInput(alice, 1000);
    }

    function test_blacklistedRouter_reverts_whenRouterNotVerified() public {
        _deployHook();

        hook.setBlacklist(key, address(msgSenderSwapRouter), true);

        _expectBeforeSwapWrappedRevert(CustomFeeAntiMevHook.Blacklisted.selector);
        _swapSellExactInput(alice, 1000);
    }

    function test_verifiedRouter_withoutMsgSender_reverts() public {
        _deployHook();

        hook.setVerifiedRouter(key, address(swapRouter), true);

        bool zeroForOne = Currency.unwrap(taxToken) == Currency.unwrap(key.currency0);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(uint256(1000)), sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        _expectBeforeSwapWrappedRevert(CustomFeeAntiMevHook.RouterDoesNotImplementMsgSender.selector);
        swapRouter.swap(
            key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), ZERO_BYTES
        );
    }

    function test_protect_oneTradePerBlock_reverts() public {
        _deployHook();

        hook.setVerifiedRouter(key, address(msgSenderSwapRouter), true);
        hook.protect(key);

        _swapSellExactInput(alice, 100);
        _expectBeforeSwapWrappedRevert(CustomFeeAntiMevHook.OneTradePerBlock.selector);
        _swapSellExactInput(alice, 100);
    }

    function test_protect_oneTradePerBlock_isPerSwapper() public {
        _deployHook();

        hook.setVerifiedRouter(key, address(msgSenderSwapRouter), true);
        hook.protect(key);

        _swapSellExactInput(alice, 100);
        _swapSellExactInput(bob, 100);
    }

    function test_protect_cooldown_reverts() public {
        _deployHook();

        hook.setVerifiedRouter(key, address(msgSenderSwapRouter), true);
        hook.setCooldownSeconds(key, 100);
        hook.protect(key);

        vm.warp(1000);
        _swapSellExactInput(alice, 100);

        vm.roll(block.number + 1);
        vm.warp(1050);

        _expectBeforeSwapWrappedRevert(CustomFeeAntiMevHook.CooldownActive.selector);
        _swapSellExactInput(alice, 100);
    }

    function test_maxSellExceeded_onlyOnSell() public {
        _deployHook();

        hook.setMaxSellAmount(key, 50);

        _expectBeforeSwapWrappedRevert(CustomFeeAntiMevHook.MaxSellExceeded.selector);
        _swapSellExactInput(alice, 100);

        vm.roll(block.number + 1);
        _swapBuyExactInput(alice, 100);
    }

    function test_feeOverride_buyAndSell_changesOutput() public {
        _deployHook();

        uint256 amountIn = 100_000;

        uint256 snap = vm.snapshotState();
        hook.setSellFeeBps(key, 100_000);
        BalanceDelta higherFeeSell = _swapSellExactInput(alice, amountIn);
        vm.revertToState(snap);

        hook.setSellFeeBps(key, 1000);
        BalanceDelta lowerFeeSell = _swapSellExactInput(alice, amountIn);

        assertGt(_sellOutput(lowerFeeSell), _sellOutput(higherFeeSell));

        snap = vm.snapshotState();
        hook.setBuyFeeBps(key, 100_000);
        BalanceDelta higherFeeBuy = _swapBuyExactInput(alice, amountIn);
        vm.revertToState(snap);

        hook.setBuyFeeBps(key, 1000);
        BalanceDelta lowerFeeBuy = _swapBuyExactInput(alice, amountIn);

        assertGt(_buyOutput(lowerFeeBuy), _buyOutput(higherFeeBuy));
    }

    function test_afterInitialize_setsDefaultFeesAndTargetToken() public {
        _deployHook();

        (uint24 buyFeeBps, uint24 sellFeeBps, address targetToken,,,) = hook.getPoolState(key);

        assertEq(buyFeeBps, hook.DEFAULT_FEE_BPS());
        assertEq(sellFeeBps, hook.DEFAULT_FEE_BPS());
        assertEq(targetToken, Currency.unwrap(taxToken));
    }

    function test_afterInitialize_noopsForNonNativePools() public {
        _deployHook();

        Currency other = deployMintAndApproveCurrency();
        Currency tokenCurrency = Currency.wrap(address(token));
        (Currency c0, Currency c1) =
            Currency.unwrap(tokenCurrency) < Currency.unwrap(other) ? (tokenCurrency, other) : (other, tokenCurrency);

        PoolKey memory key2 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        manager.initialize(key2, SQRT_PRICE_1_1);

        (uint24 buyFeeBps, uint24 sellFeeBps, address targetToken,,,) = hook.getPoolState(key2);

        assertEq(buyFeeBps, hook.DEFAULT_FEE_BPS());
        assertEq(sellFeeBps, hook.DEFAULT_FEE_BPS());
        assertEq(targetToken, address(0));
    }

    function test_afterInitialize_clearsTargetTokenWhenOwnerMissing() public {
        _deployHook();

        NonOwnableMintableERC20 noOwnerToken = new NonOwnableMintableERC20("NOOWNER", "NOOWNER");
        noOwnerToken.mint(address(this), 1_000_000 ether);

        Currency noOwnerCurrency = Currency.wrap(address(noOwnerToken));
        (Currency c0, Currency c1) =
            Currency.unwrap(noOwnerCurrency) < Currency.unwrap(currency0) ? (noOwnerCurrency, currency0) : (currency0, noOwnerCurrency);

        PoolKey memory key2 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        manager.initialize(key2, SQRT_PRICE_1_1);

        (uint24 buyFeeBps, uint24 sellFeeBps, address targetToken,,,) = hook.getPoolState(key2);

        assertEq(buyFeeBps, hook.DEFAULT_FEE_BPS());
        assertEq(sellFeeBps, hook.DEFAULT_FEE_BPS());
        assertEq(targetToken, address(0));
    }

    function test_afterInitialize_clearsTargetTokenWhenOwnerRenounced() public {
        _deployHook();

        OwnableMintableERC20 renouncedToken = new OwnableMintableERC20("RENOUNCED", "RENOUNCED", address(this));
        renouncedToken.renounceOwnership();

        Currency renouncedCurrency = Currency.wrap(address(renouncedToken));
        (Currency c0, Currency c1) =
            Currency.unwrap(renouncedCurrency) < Currency.unwrap(currency0)
                ? (renouncedCurrency, currency0)
                : (currency0, renouncedCurrency);

        PoolKey memory key2 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        manager.initialize(key2, SQRT_PRICE_1_1);

        (,, address targetToken,,,) = hook.getPoolState(key2);

        assertEq(targetToken, address(0));
    }

    function test_feeCalculation_sell_exactInput_matchesNetInput() public {
        _deployHook();

        uint256 amountIn = 100_000;
        uint24 feeBps = 50_000; // 5%
        uint256 amountInNet = (amountIn * (1_000_000 - feeBps)) / 1_000_000;

        uint256 snap = vm.snapshotState();
        hook.setSellFeeBps(key, feeBps);
        uint256 outWithFee = uint256(int256(_sellOutput(_swapSellExactInput(alice, amountIn))));
        vm.revertToState(snap);

        hook.setSellFeeBps(key, 0);
        uint256 outNetInput = uint256(int256(_sellOutput(_swapSellExactInput(alice, amountInNet))));

        assertApproxEqAbs(outWithFee, outNetInput, 2);
    }

    function test_feeCalculation_buy_exactInput_matchesNetInput() public {
        _deployHook();

        uint256 amountIn = 100_000;
        uint24 feeBps = 120_000; // 12%
        uint256 amountInNet = (amountIn * (1_000_000 - feeBps)) / 1_000_000;

        uint256 snap = vm.snapshotState();
        hook.setBuyFeeBps(key, feeBps);
        uint256 outWithFee = uint256(int256(_buyOutput(_swapBuyExactInput(alice, amountIn))));
        vm.revertToState(snap);

        hook.setBuyFeeBps(key, 0);
        uint256 outNetInput = uint256(int256(_buyOutput(_swapBuyExactInput(alice, amountInNet))));

        assertApproxEqAbs(outWithFee, outNetInput, 2);
    }

    function test_onlyTokenOwner_allowsOwner() public {
        _deployHook();

        hook.setBuyFeeBps(key, 1234);

        (uint24 buyFeeBps,,,,,) = hook.getPoolState(key);
        assertEq(buyFeeBps, 1234);
    }

    function test_onlyTokenOwner_revertsForNonOwner() public {
        _deployHook();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomFeeAntiMevHook.NotTokenOwner.selector,
                address(token),
                address(this),
                alice
            )
        );
        hook.setBuyFeeBps(key, 1234);
    }
}
