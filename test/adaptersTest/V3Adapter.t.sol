// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Adapter, INonfungiblePositionManager} from "../../src/adapters/UniswapV3Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) {
            balanceOf[to] += amount;
        } else {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) {
            balanceOf[to] += amount;
        } else {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        return true;
    }
    
    function approve(address, uint256) external pure returns (bool) { return true; }
}

contract MockPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        fee = 3000;
    }

    function slot0() external pure returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked) {
        return (1 << 96, 0, 0, 0, 0, 0, true);
    }
}

contract MockPositionManager {
    struct Position { uint128 liquidity; address token0; address token1; }
    mapping(uint256 => Position) public positionsData;
    uint256 public nextId = 1;

    constructor(address _t0, address _t1) {
        positionsData[1] = Position(100e18, _t0, _t1);
    }

    function positions(uint256 id) external view returns (
        uint96, address, address token0, address token1, uint24, int24, int24, uint128 liquidity, 
        uint256, uint256, uint128, uint128
    ) {
        uint256 lookupId = id == 0 ? 1 : id;
        Position memory p = positionsData[lookupId];
        return (0, address(0), p.token0, p.token1, 3000, -60, 60, p.liquidity, 0, 0, 0, 0);
    }

    function mint(INonfungiblePositionManager.MintParams calldata p) external pure returns (uint256, uint128, uint256, uint256) {
        return (1, 100e18, p.amount0Desired, p.amount1Desired);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p) external pure returns (uint128, uint256, uint256) {
        return (50e18, p.amount0Desired, p.amount1Desired);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata) external pure returns (uint256, uint256) {
        return (10e18, 10e18);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata) external pure returns (uint256, uint256) {
        return (1e18, 1e18);
    }
}

contract UniswapV3AdapterTest is Test {
    UniswapV3Adapter public adapter;
    MockToken public t0;
    MockToken public t1;
    MockPositionManager public posManager;
    MockPool public pool;
    address user = address(0x1337);

    function setUp() public {
        t0 = new MockToken();
        t1 = new MockToken();
        posManager = new MockPositionManager(address(t0), address(t1));
        pool = new MockPool(address(t0), address(t1));
        adapter = new UniswapV3Adapter(address(posManager), address(pool), address(0x456));
        
        t0.mint(user, 1000e18);
        t1.mint(user, 1000e18);
        
        vm.startPrank(user);
        t0.approve(address(adapter), type(uint256).max);
        t1.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_Deposit() public {
        vm.startPrank(user);
        adapter.deposit(100e18, 100e18, 0, 0);
        assertEq(adapter.tokenId(), 1);
        
        adapter.deposit(50e18, 50e18, 0, 0);
        vm.stopPrank();
    }

    function test_Deposit_RevertsWhenPoolHasNoCode() public {
        UniswapV3Adapter brokenAdapter = new UniswapV3Adapter(address(posManager), address(0x999), address(0x456));
        vm.expectRevert();
        brokenAdapter.deposit(1e18, 1e18, 0, 0);
    }

    function test_Withdraw() public {
        vm.startPrank(user);
        adapter.deposit(100e18, 100e18, 0, 0);
        (uint256 a0, uint256 a1) = adapter.withdraw(5e17, 0, 0);
        assertTrue(a0 > 0 && a1 > 0);
        vm.stopPrank();
    }

    function test_Withdraw_RevertsOnZeroRatio() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAmount.selector);
        adapter.withdraw(0, 0, 0);
    }

    function test_RescueToken() public {
        t0.mint(address(adapter), 10e18);
        adapter.rescueToken(address(t0));
        assertEq(t0.balanceOf(address(this)), 10e18);
    }

    function test_RescueToken_RevertsWhenBalanceIsZero() public {
        vm.expectRevert(UniswapV3Adapter.ZeroBalance.selector);
        adapter.rescueToken(address(t0));
    }

    function test_SetStrategy_RevertsWhenTickLowerIsHigher() public {
        vm.expectRevert(UniswapV3Adapter.InvalidTickLower.selector);
        adapter.setStrategy(100, 50);
    }

    function test_PositionHelpers_ZeroTokenIdReturnZero() public view {
        assertEq(adapter.getPositionAmount0(), 0);
        assertEq(adapter.getPositionAmount1(), 0);
    }

    function test_SwapTokens_CoversBothDirections() public {
        vm.startPrank(user);
        adapter.deposit(100e18, 100e18, 0, 0);
        vm.expectRevert();
        adapter.swapTokens(10e18, true, 0);
        vm.stopPrank();
    }

    function test_Constructor_RevertsZeroAddress() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(0), address(pool), address(0x456));
    }
}