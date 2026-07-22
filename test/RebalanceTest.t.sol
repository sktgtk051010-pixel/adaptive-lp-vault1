// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdaptiveIPVault} from "../src/AdaptiveIPVault.sol";
import {MockToken, MockVenueAdapter, MockOracle} from "./utils/MockUtils.sol";

contract RebalanceTest is Test {
    AdaptiveIPVault public vault;
    MockToken public token0;
    MockToken public token1;
    MockVenueAdapter public adapter;
    MockOracle public oracle;

    function setUp() public {
        token0 = new MockToken();
        token1 = new MockToken();
        adapter = new MockVenueAdapter();
        oracle = new MockOracle();

        vault = new AdaptiveIPVault(
            "Vault", "VLT", 
            address(token0), address(token1), 
            address(adapter), address(oracle), 
            address(token0), 11000, 100e18
        );
    }

    function test_Rebalance_PanicTrigger() public {
        oracle.setTicks(1000, 0); 
        token0.mint(address(vault), 100e18);
        token1.mint(address(vault), 100e18);
        vault.rebalance();
        assertGt(vault.lastRebalanceTimestamp(), 0);
    }

    function test_Rebalance_CooldownTrigger() public {
        vm.warp(block.timestamp + 4000); 
        token0.mint(address(vault), 100e18);
        token1.mint(address(vault), 100e18);
        vault.rebalance();
        assertGt(vault.lastRebalanceTimestamp(), 0);
    }

    function test_Rebalance_SwapLogic_FullCheck() public {
        adapter.setMockBalances(2000e18, 100e18);
        oracle.setTicks(1000, 0); 
        
        token0.mint(address(vault), 1000e18);
        token1.mint(address(vault), 100e18);
        
        vault.rebalance();
    
        assertTrue(adapter.lastIsZeroForOne(), "Should swap 0 for 1");
        assertGt(adapter.lastSwapAmount(), 0, "Swap amount must be positive");
    }

    function test_Revert_RebalanceNotReady() public {
        oracle.setTicks(0, 0); 
        vm.expectRevert();
        vault.rebalance();
    }
}