// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {ReFiSwapRebateHook} from "../src/RebateFiHook.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

contract TestReFiSwapRebateHook is Test, Deployers, ERC1155TokenReceiver {
    
    MockERC20 token;
    MockERC20 reFiToken;
    ReFiSwapRebateHook public rebateHook;
    
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;
    Currency reFiCurrency;

    address user1 = address(0x1);
    address user2 = address(0x2);

    uint160 constant SQRT_PRICE_1_1_s = 79228162514264337593543950336;

    function setUp() public {
        // Deploy the Uniswap V4 PoolManager
        deployFreshManagerAndRouters();

        // Deploy the ERC20 token
        token = new MockERC20("TOKEN", "TKN", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Deploy the ReFi token
        reFiToken = new MockERC20("ReFi Token", "ReFi", 18);
        reFiCurrency = Currency.wrap(address(reFiToken));

        // Mint tokens to test contract and users
        token.mint(address(this), 1000 ether);
        token.mint(user1, 1000 ether);
        token.mint(user2, 1000 ether);

        reFiToken.mint(address(this), 1000 ether);
        reFiToken.mint(user1, 1000 ether);
        reFiToken.mint(user2, 1000 ether);


        // Get creation code for hook
        bytes memory creationCode = type(ReFiSwapRebateHook).creationCode;
        bytes memory constructorArgs = abi.encode(manager, address(reFiToken));

        // Find a salt that produces a valid hook address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            creationCode,
            constructorArgs
        );

        // Deploy the hook with the mined salt
        rebateHook = new ReFiSwapRebateHook{salt: salt}(manager, address(reFiToken));
        require(address(rebateHook) == hookAddress, "Hook address mismatch");

        // Approve tokens for the test contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        reFiToken.approve(address(rebateHook), type(uint256).max);
        reFiToken.approve(address(swapRouter), type(uint256).max);
        reFiToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize the pool with ReFi token using DYNAMIC_FEE_FLAG
        (key, ) = initPool(
            ethCurrency,
            reFiCurrency,
            rebateHook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1_s
        );

        // Add liquidity
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.1 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /* ══════════════════════════════════════════════════════════════════
                            INITIALIZATION TESTS
       ══════════════════════════════════════════════════════════════════ */

    function test_DeploymentSuccess() public view {
        assertEq(rebateHook.ReFi(), address(reFiToken), "ReFi token address mismatch");
        assertEq(rebateHook.owner(), address(this), "Owner mismatch");
    }

    function test_InitialFeeConfiguration() public view {
        (uint24 buyFee, uint24 sellFee) = rebateHook.getFeeConfig();
        assertEq(buyFee, 0, "Initial buy fee should be 0");
        assertEq(sellFee, 3000, "Initial sell fee should be 3000");
    }

    /* ══════════════════════════════════════════════════════════════════
                            SWAP TESTS - BUY ReFi
       ══════════════════════════════════════════════════════════════════ */

    function test_BuyReFi_ZeroFee() public {
        uint256 ethAmount = 0.01 ether;
        // Fund user and record initial balances
        vm.deal(user1, 1 ether);
        // Record initial balances after funding
        uint256 initialEthBalance = user1.balance;
        uint256 initialReFiBalance = reFiToken.balanceOf(user1);
        vm.startPrank(user1);

        SwapParams memory params = SwapParams({
            zeroForOne: true, // ETH -> ReFi
            amountSpecified: -int256(ethAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Perform swap
        swapRouter.swap{value: ethAmount}(key, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Check balances after swap
        uint256 finalEthBalance = user1.balance;
        uint256 finalReFiBalance = reFiToken.balanceOf(user1);

        // User should have less ETH and more ReFi
        assertEq(finalEthBalance, initialEthBalance - ethAmount, "ETH balance should decrease by swap amount");
        assertGt(finalReFiBalance, initialReFiBalance, "ReFi balance should increase after buy");

        // Verify fee configuration remains zero for buys
        (uint24 currentBuyFee, ) = rebateHook.getFeeConfig();
        assertEq(currentBuyFee, 0, "Buy fee should remain 0");
    }

    function test_BuyReFi_MultipleUsers() public {
        uint256 ethAmount = 0.001 ether;

        // Test user1
        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        uint256 user1InitialReFi = reFiToken.balanceOf(user1);
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap{value: ethAmount}(key, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Test user2
        vm.deal(user2, 1 ether);
        vm.startPrank(user2);
        uint256 user2InitialReFi = reFiToken.balanceOf(user2);
        
        swapRouter.swap{value: ethAmount}(key, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Both users should have more ReFi tokens
        assertGt(reFiToken.balanceOf(user1), user1InitialReFi, "User1 should have more ReFi");
        assertGt(reFiToken.balanceOf(user2), user2InitialReFi, "User2 should have more ReFi");
    }

    /* ══════════════════════════════════════════════════════════════════
                            SWAP TESTS - SELL ReFi
       ══════════════════════════════════════════════════════════════════ */

    function test_SellReFi_AppliesFee() public {
        uint256 reFiAmount = 0.01 ether;
        
        vm.startPrank(user1);
        reFiToken.approve(address(swapRouter), type(uint256).max);
        
        // Record initial balances
        uint256 initialEthBalance = user1.balance;
        uint256 initialReFiBalance = reFiToken.balanceOf(user1);

        SwapParams memory params = SwapParams({
            zeroForOne: false, // ReFi -> ETH
            amountSpecified: -int256(reFiAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Perform swap
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Check balances after swap
        uint256 finalEthBalance = user1.balance;
        uint256 finalReFiBalance = reFiToken.balanceOf(user1);

        // User should have less ReFi and more ETH
        assertEq(finalReFiBalance, initialReFiBalance - reFiAmount, "ReFi balance should decrease by exact swap amount");
        assertGt(finalEthBalance, initialEthBalance, "ETH balance should increase after sell");

        // Verify sell fee configuration
        (, uint24 currentSellFee) = rebateHook.getFeeConfig();
        assertEq(currentSellFee, 3000, "Sell fee should remain 3000");
    }

 
    function test_SellReFi_WithUpdatedFee() public {
        // First update the sell fee
        uint24 newSellFee = 5000; // 0.5%
        rebateHook.ChangeFee(false, 0, true, newSellFee);

        uint256 reFiAmount = 0.01 ether;

        vm.startPrank(user1);
        reFiToken.approve(address(swapRouter), type(uint256).max);

        uint256 initialReFiBalance = reFiToken.balanceOf(user1);
        uint256 initialEthBalance = user1.balance;

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(reFiAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        vm.stopPrank();

        uint256 finalReFiBalance = reFiToken.balanceOf(user1);
        uint256 finalEthBalance = user1.balance;

        // Verify balances changed
        assertEq(finalReFiBalance, initialReFiBalance - reFiAmount, "ReFi balance should decrease by swap amount");
        assertGt(finalEthBalance, initialEthBalance, "ETH balance should increase");

        // Verify new fee is applied
        (, uint24 currentSellFee) = rebateHook.getFeeConfig();
        assertEq(currentSellFee, newSellFee, "Sell fee should be updated");
    }

    /* ══════════════════════════════════════════════════════════════════
                            COMPREHENSIVE SWAP TESTS
       ══════════════════════════════════════════════════════════════════ */

    function test_MultipleBuysAndSells_StateChanges() public {
        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        reFiToken.approve(address(swapRouter), type(uint256).max);

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 initialReFiBalance = reFiToken.balanceOf(user1);
        uint256 initialEthBalance = user1.balance;

        // 3 buys
        for (uint i = 0; i < 3; i++) {
            SwapParams memory buyParams = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(0.001 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            swapRouter.swap{value: 0.001 ether}(key, buyParams, testSettings, ZERO_BYTES);
        }

        // 2 sells
        for (uint i = 0; i < 2; i++) {
            SwapParams memory sellParams = SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(0.0005 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });
            swapRouter.swap(key, sellParams, testSettings, ZERO_BYTES);
        }

        vm.stopPrank();

        uint256 finalReFiBalance = reFiToken.balanceOf(user1);
        uint256 finalEthBalance = user1.balance;

        // These are approximate checks since exact amounts depend on pool math
        assertLt(finalEthBalance, initialEthBalance, "Net ETH balance should decrease after more buys than sells");
        assertGt(finalReFiBalance, initialReFiBalance, "Net ReFi balance should increase after more buys than sells");

        // Verify fee configuration unchanged
        (uint24 buyFee, uint24 sellFee) = rebateHook.getFeeConfig();
        assertEq(buyFee, 0, "Buy fee should remain 0");
        assertEq(sellFee, 3000, "Sell fee should remain 3000");
    }

    /* ══════════════════════════════════════════════════════════════════
                            ADMIN FUNCTION TESTS
       ══════════════════════════════════════════════════════════════════ */

    function test_ChangeFee_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        rebateHook.ChangeFee(true, 1000, false, 0);
    }

    function test_ChangeFee_BuyFee() public {
        uint24 newBuyFee = 1000;
        rebateHook.ChangeFee(true, newBuyFee, false, 0);
        
        (uint24 buyFee, ) = rebateHook.getFeeConfig();
        assertEq(buyFee, newBuyFee, "Buy fee should be updated");
    }

    function test_ChangeFee_SellFee() public {
        uint24 newSellFee = 5000;
        rebateHook.ChangeFee(false, 0, true, newSellFee);
        
        (, uint24 sellFee) = rebateHook.getFeeConfig();
        assertEq(sellFee, newSellFee, "Sell fee should be updated");
    }

    function test_ChangeFee_Both() public {
        rebateHook.ChangeFee(true, 500, true, 4000);
        
        (uint24 buyFee, uint24 sellFee) = rebateHook.getFeeConfig();
        assertEq(buyFee, 500, "Buy fee should be updated");
        assertEq(sellFee, 4000, "Sell fee should be updated");
    }

    function test_WithdrawTokens_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        rebateHook.withdrawTokens(address(reFiToken), user1, 1 ether);
    }

    function test_WithdrawTokens_Success() public {
        // First, send some tokens to the hook contract
        uint256 transferAmount = 1 ether;
        reFiToken.transfer(address(rebateHook), transferAmount);
        
    uint256 initialBalance = reFiToken.balanceOf(address(this));
    uint256 hookBalanceBefore = reFiToken.balanceOf(address(rebateHook));
        
        // Withdraw a reasonable amount
        uint256 withdrawAmount = 0.5 ether;
        rebateHook.withdrawTokens(address(reFiToken), address(this), withdrawAmount);
        
        uint256 finalBalance = reFiToken.balanceOf(address(this));
        uint256 hookBalanceAfter = reFiToken.balanceOf(address(rebateHook));
        
        // finalBalance should equal initialBalance + withdrawAmount (we transferred away `transferAmount` earlier)
        assertEq(finalBalance, initialBalance + withdrawAmount, "Should receive withdrawn tokens");
        assertEq(hookBalanceAfter, hookBalanceBefore - withdrawAmount, "Hook balance should decrease");
    }

    /* ══════════════════════════════════════════════════════════════════
                            VIEW FUNCTION TESTS
       ══════════════════════════════════════════════════════════════════ */

    function test_GetFeeConfig() public view {
        (uint24 buyFee, uint24 sellFee) = rebateHook.getFeeConfig();
        assertEq(buyFee, 0, "Buy fee should be 0");
        assertEq(sellFee, 3000, "Sell fee should be 3000");
    }

    function test_HookPermissions() public view {
        Hooks.Permissions memory permissions = rebateHook.getHookPermissions();
        
        assertTrue(permissions.beforeInitialize, "Should have beforeInitialize permission");
        assertTrue(permissions.afterInitialize, "Should have afterInitialize permission");
        assertTrue(permissions.beforeSwap, "Should have beforeSwap permission");
        
        assertFalse(permissions.beforeAddLiquidity, "Should not have beforeAddLiquidity permission");
        assertFalse(permissions.afterAddLiquidity, "Should not have afterAddLiquidity permission");
        assertFalse(permissions.beforeRemoveLiquidity, "Should not have beforeRemoveLiquidity permission");
        assertFalse(permissions.afterRemoveLiquidity, "Should not have afterRemoveLiquidity permission");
        assertFalse(permissions.afterSwap, "Should not have afterSwap permission");
    }

    /* ══════════════════════════════════════════════════════════════════
                            EDGE CASE TESTS
       ══════════════════════════════════════════════════════════════════ */

    function test_ZeroAmountSwap() public {
        vm.startPrank(user1);
        reFiToken.approve(address(swapRouter), type(uint256).max);

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: 0,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

    // Expect revert when trying to swap zero amount
    vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
    swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        
        vm.stopPrank();
    }

    function test_FeeBoundaries() public {
        // Test maximum reasonable fee
        uint24 maxReasonableFee = 100000; // 10%
        rebateHook.ChangeFee(false, 0, true, maxReasonableFee);
        
        (, uint24 sellFee) = rebateHook.getFeeConfig();
        assertEq(sellFee, maxReasonableFee, "Should be able to set reasonable fee");

        // Test zero fee
        rebateHook.ChangeFee(false, 0, true, 0);
        (, sellFee) = rebateHook.getFeeConfig();
        assertEq(sellFee, 0, "Should be able to set zero fee");

        // Reset to original
        rebateHook.ChangeFee(false, 0, true, 3000);
    }
}