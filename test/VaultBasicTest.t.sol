// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdaptiveIPVault} from "../src/AdaptiveIPVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken, MockVenueAdapter, MockOracle} from "./utils/MockUtils.sol";

// --- 正式测试 ---
contract VaultBasicTest is Test {
    AdaptiveIPVault public vault;
    MockToken public token0;
    MockToken public token1;
    MockVenueAdapter public adapter;
    MockOracle public oracle;
    
    // --- 确保这里定义了 user ---
    address public user = address(0x1337); 

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

    function test_Deposit() public {
        // 简单测试一下逻辑通不通，这里只是触发一下
        // 因为 MockToken 还没写完整的逻辑，这里先测试构造和初始化
        assertEq(address(vault.venueAdapter()), address(adapter));
    }

    // 补全：测试取款逻辑
    function test_Withdraw() public {
        token0.mint(user, 1000e18);
        token1.mint(user, 1000e18);
        
        vm.startPrank(user);
        // 先存
        vault.deposit(100e18, 100e18, 0, 0);
        // 再取
        vault.withdraw(50e18, 0, 0);
        
        // 验证余额变化（Mock adapter 每次 withdraw 返回 10e18）
        assertEq(token0.balanceOf(user), 910e18); // 初始1000 - 存100 + 取10
        vm.stopPrank();
    }

    // 补全：测试设置 Bounty Config
    function test_SetBountyConfig() public {
        // 原默认值是 100e18，改为 200e18
        vault.setBountyConfig(12000, 200e18);
        assertEq(vault.premiumMultiplierBps(), 12000);
        assertEq(vault.maxRewardLimit(), 200e18);
    }

    // 补全：测试设置 CooldownTiers
    function test_SetCooldownTiers() public {
        AdaptiveIPVault.CooldownTier[] memory newTiers = new AdaptiveIPVault.CooldownTier[](1);
        newTiers[0] = AdaptiveIPVault.CooldownTier({tickDeltaThreshold: 500, cooldownSeconds: 600});
        
        vault.setCooldownTiers(newTiers);
        
        // 修正点：将变量名 seconds 改为 cooldownSeconds_
        (uint24 threshold, uint32 cooldownSeconds_) = vault.cooldownTiers(0);
        
        assertEq(threshold, 500);
        assertEq(cooldownSeconds_, 600);
    }

    // 补全：测试权限（非 owner 调用失败）
    function test_Revert_NotOwner() public {
        vm.startPrank(address(0x999));
        vm.expectRevert(); // 预期 Ownable 报错
        vault.setBountyConfig(12000, 200e18);
        vm.stopPrank();
    }
}