// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdaptiveIPVault} from "../src/AdaptiveIPVault.sol";
import {MockToken, MockVenueAdapter, MockOracle} from "./utils/MockUtils.sol";

contract VaultFuzzInvariantTest is Test {
    AdaptiveIPVault public vault;
    MockToken public token0;
    MockToken public token1;
    MockVenueAdapter public adapter;
    MockOracle public oracle;

    address public user = address(0x1337);

    function setUp() public {
        token0 = new MockToken();
        token1 = new MockToken();
        adapter = new MockVenueAdapter();
        oracle = new MockOracle();

        vault = new AdaptiveIPVault(
            "Vault",
            "VLT",
            address(token0),
            address(token1),
            address(adapter),
            address(oracle),
            address(token0),
            11000,
            100e18
        );

        token0.mint(user, 1000000e18);
        token1.mint(user, 1000000e18);
    }

    function testFuzz_Deposit_MintsSharesForAnyPositiveAmount(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 1, 1000000e18);
        amount1 = bound(amount1, 1, 1000000e18);

        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.deposit(amount0, amount1, 0, 0);
        vm.stopPrank();

        assertGt(vault.balanceOf(user), 0);
        assertEq(vault.totalSupply(), vault.balanceOf(user));
    }

    function testFuzz_SetBountyConfig_RejectsInvalidValues(uint256 premium, uint256 maxLimit) public {
        vm.assume(premium < 10000 || maxLimit == 0);

        uint256 previousPremium = vault.premiumMultiplierBps();
        uint256 previousLimit = vault.maxRewardLimit();

        vm.expectRevert();
        vault.setBountyConfig(premium, maxLimit);

        assertEq(vault.premiumMultiplierBps(), previousPremium);
        assertEq(vault.maxRewardLimit(), previousLimit);
    }

    function testFuzz_SetCooldownTiers_RejectsInvalidCooldowns(uint32 cooldown) public {
        vm.assume(cooldown < 300);

        AdaptiveIPVault.CooldownTier[] memory tiers = new AdaptiveIPVault.CooldownTier[](1);
        tiers[0] = AdaptiveIPVault.CooldownTier({tickDeltaThreshold: 100, cooldownSeconds: cooldown});

        vm.expectRevert();
        vault.setCooldownTiers(tiers);
    }

    function depositHandler(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 1, 1000e18);
        amount1 = bound(amount1, 1, 1000e18);

        token0.mint(user, amount0);
        token1.mint(user, amount1);

        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.deposit(amount0, amount1, 0, 0);
        vm.stopPrank();
    }

    function bountyConfigHandler(uint256 premium, uint256 maxLimit) public {
        premium = bound(premium, 10000, type(uint256).max);
        maxLimit = bound(maxLimit, 1, type(uint256).max);
        vault.setBountyConfig(premium, maxLimit);
    }

    function invariant_configAlwaysValid() public view {
        assertGe(vault.premiumMultiplierBps(), 10000);
        assertGt(vault.maxRewardLimit(), 0);
    }

    function invariant_shareBalanceNeverExceedsSupply() public view {
        assertLe(vault.balanceOf(user), vault.totalSupply());
    }
}
