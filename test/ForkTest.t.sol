// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AdaptiveIPVault} from "../src/AdaptiveIPVault.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {TWAPOracle} from "../src/TWAPOracle.sol";
import "forge-std/console.sol";

contract ForkTest is Test {
    AdaptiveIPVault public vault;
    UniswapV3Adapter public myAdapter;
    TWAPOracle public oracle;

    address constant POS_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant POOL = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address constant WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        myAdapter = new UniswapV3Adapter(POS_MANAGER, POOL, ROUTER);
        oracle = new TWAPOracle(POOL, USDC, true, 300, 60);

        (, int24 currentTick, , , , , ) = myAdapter.pool().slot0();
        int24 tickSpacing = myAdapter.pool().tickSpacing();
        int24 baseTick = currentTick / tickSpacing * tickSpacing;
        int24 tickLower = baseTick - tickSpacing * 10;
        int24 tickUpper = baseTick + tickSpacing * 10;
        myAdapter.setStrategy(tickLower, tickUpper);

        vault = new AdaptiveIPVault(
            "AdaptiveVault",
            "AVLT",
            USDC,
            WETH,
            address(myAdapter),
            address(oracle),
            USDC,
            11000,
            100e6
        );
    }

    function test_Fork_Connectivity() public view {
        assertEq(address(vault.venueAdapter()), address(myAdapter));
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(vault.token0(), USDC);
        assertEq(vault.token1(), WETH);
        assertTrue(address(vault) != address(0));
    }

    function test_Deposit_And_Withdraw_Flow() public {
        _fundWhale();

        vm.startPrank(WHALE);
        uint256 amount0 = 1000e6;
        uint256 amount1 = 0.5e18;

        IERC20(USDC).approve(address(vault), amount0);
        IERC20(WETH).approve(address(vault), amount1);

        vault.deposit(amount0, amount1, 0, 0);

        uint256 shares = vault.balanceOf(WHALE);
        assertGt(shares, 0);

        vm.expectRevert();
        vault.withdraw(shares, 0, 0);
        vm.stopPrank();
    }

    function test_Compatibility_Switching() public {
        assertEq(address(vault.venueAdapter()), address(myAdapter));

        UniswapV2Adapter v2Adapter = new UniswapV2Adapter(V2_ROUTER, V2_PAIR, USDC, WETH);
        vault.setVenueAdapter(address(v2Adapter));

        assertEq(address(vault.venueAdapter()), address(v2Adapter));
    }

    function test_Rebalance_RequiresReadiness() public {
        _fundWhale();

        vm.startPrank(WHALE);
        uint256 amount0 = 1000e6;
        uint256 amount1 = 0.5e18;

        IERC20(USDC).approve(address(vault), amount0);
        IERC20(WETH).approve(address(vault), amount1);
        vault.deposit(amount0, amount1, 0, 0);
        vm.stopPrank();

        vm.expectRevert();
        vault.rebalance();
    }

    function _fundWhale() internal {
        deal(USDC, WHALE, 10000e6);
        deal(WETH, WHALE, 10 ether);
    }
}
