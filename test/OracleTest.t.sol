// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TWAPOracle} from "../src/TWAPOracle.sol";
import {TickMath} from "../src/compat/TickMath.sol";

// ─── 🛡️ 大厂规范：编写外部依赖的极简 Mock ───

contract MockV3Pool {
    int56[] private mockTickCumulatives;

    function setMockData(int56 tick0, int56 tick1) external {
        delete mockTickCumulatives;
        mockTickCumulatives.push(tick0);
        mockTickCumulatives.push(tick1);
    }

    function observe(uint32[] calldata /* secondsAgos */) 
        external 
        view 
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128) 
    {
        return (mockTickCumulatives, new uint160[](2));
    }
}

contract MockV2Pair {
    address public immutable token0;
    uint112 private res0;
    uint112 private res1;

    constructor(address _token0) {
        token0 = _token0;
    }

    function setReserves(uint112 _res0, uint112 _res1) external {
        res0 = _res0;
        res1 = _res1;
    }

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return (res0, res1, uint32(block.timestamp));
    }
}

// ─── 🚀 核心测试合约 ───

contract OracleTest is Test {
    TWAPOracle public v3Oracle;
    TWAPOracle public v2OracleToken0Base;
    TWAPOracle public v2OracleToken1Base;

    MockV3Pool public mockV3Pool;
    MockV2Pair public mockV2Pair;

    address public constant VAULT_BASE_TOKEN = address(0x1111);
    address public constant OTHER_TOKEN = address(0x2222);

    uint32 public constant TWAP_PERIOD = 1800;       // 30分钟
    uint32 public constant FAST_TWAP_PERIOD = 300;   // 5分钟

    function setUp() public {
        // 1. 部署 Mock 外部池子
        mockV3Pool = new MockV3Pool();
        mockV2Pair = new MockV2Pair(VAULT_BASE_TOKEN); // token0 是本位币

        // 2. 部署 Uniswap V3 模式的预言机
        v3Oracle = new TWAPOracle(
            address(mockV3Pool),
            VAULT_BASE_TOKEN,
            true, // isV3
            TWAP_PERIOD,
            FAST_TWAP_PERIOD
        );

        // 3. 部署 Uniswap V2 模式的预言机（Token0 是本位币）
        v2OracleToken0Base = new TWAPOracle(
            address(mockV2Pair),
            VAULT_BASE_TOKEN,
            false, // isV3
            TWAP_PERIOD,
            FAST_TWAP_PERIOD
        );

        // 4. 部署 Uniswap V2 模式的预言机（Token1 是本位币）
        // 构造传参将其他代币设为 Base，引发 !isV2Token0Base 分支
        v2OracleToken1Base = new TWAPOracle(
            address(mockV2Pair),
            OTHER_TOKEN,
            false,
            TWAP_PERIOD,
            FAST_TWAP_PERIOD
        );
    }

    // ─── ⚙️ 1. 构造函数与边界风控测试 ───

    function test_ConstructorInit() public view {
        assertEq(v3Oracle.isV3(), true);
        assertEq(v2OracleToken0Base.isV3(), false);
        assertEq(v2OracleToken0Base.isV2Token0Base(), true);
        assertEq(v2OracleToken1Base.isV2Token0Base(), false);
    }

    function test_RevertWhen_TargetIsZeroAddress() public {
        vm.expectRevert(TWAPOracle.InvalidTargetPool.selector);
        new TWAPOracle(address(0), VAULT_BASE_TOKEN, true, TWAP_PERIOD, FAST_TWAP_PERIOD);
    }

    function test_RevertWhen_PeriodIsZero() public {
        vm.expectRevert(TWAPOracle.InvalidTwapPeriod.selector);
        new TWAPOracle(address(mockV3Pool), VAULT_BASE_TOKEN, true, 0, FAST_TWAP_PERIOD);
    }

    // ─── 📈 2. Uniswap V3 TWAP 分支测试 ───

    function test_V3_GetTwapTick_PositiveDelta() public {
        // 模拟价格向上走：30分钟前累计 Tick 为 100,000，当前为 154,000
        // Delta = 54,000. 周期 = 1800. 平均 Tick = 54,000 / 1800 = 30
        mockV3Pool.setMockData(100000, 154000);
        int24 tick = v3Oracle.getTwapTick();
        assertEq(tick, 30);
    }

    function test_V3_GetTwapTick_NegativeDeltaWithRounding() public {
        // 模拟价格向下走且有整除余数，验证代码中的向下取整（arithmeticMeanTick--）逻辑
        // Delta = -54001. 周期 = 1800. -54001 / 1800 = -30, 余数不为0，应该触发减1变为 -31
        mockV3Pool.setMockData(154000, 99999);
        int24 tick = v3Oracle.getTwapTick();
        assertEq(tick, -31);
    }

    function test_V3_GetFastTwapTick() public {
        // 验证 Fast 周期 (300 秒)
        // Delta = 15000. 周期 = 300. 平均 Tick = 15000 / 300 = 50
        mockV3Pool.setMockData(50000, 65000);
        int24 fastTick = v3Oracle.getFastTwapTick();
        assertEq(fastTick, 50);
    }

    // ─── 📉 3. Uniswap V2 虚拟 Tick 变换测试 ───

    function test_V2_VirtualTick_Token0Base() public {
        // 当 Token0 是金库本位币时，价格 = reserve1 / reserve0
        // 我们设置 1:1 的池子（100 WETH : 100 USDC）
        mockV2Pair.setReserves(100e18, 100e18);
        int24 tick = v2OracleToken0Base.getTwapTick();
        
        // 1:1 价格对应的 sqrtPriceX96 应接近 1 << 96，对应的 Tick 应该为 0
        assertEq(tick, 0);
    }

    function test_V2_VirtualTick_Token1Base() public {
        // 当 Token1 是金库本位币时，价格 = reserve0 / reserve1
        // 我们故意让储备量不等：reserve0 = 400e18, reserve1 = 100e18
        // 价格 = 400 / 100 = 4。开根号后 sqrtPrice = 2。
        mockV2Pair.setReserves(400e18, 100e18);
        int24 tick = v2OracleToken1Base.getTwapTick();
        
        // 价格为 4 倍时，对应的 Tick 理论值约为 13862 左右（1.0001^13862 ≈ 4）
        // 我们利用 TickMath 来逆向验证你的 _sqrt 与虚拟 Tick 转换的绝对精准度
        int24 expectedTick = TickMath.getTickAtSqrtRatio(uint160(2 * (1 << 96)));
        assertEq(tick, expectedTick);
    }

    function test_V2_ZeroReserves_ReturnsZeroTick() public {
        // 🛡️ 极端情况风控：当外部池子还没初始化，流动性为0时，应该优雅返回 0 而不是报错
        mockV2Pair.setReserves(0, 0);
        assertEq(v2OracleToken0Base.getTwapTick(), 0);
    }
}