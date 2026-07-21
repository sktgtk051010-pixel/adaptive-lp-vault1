// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;



import {Test} from "forge-std/Test.sol";

import {console} from "forge-std/console.sol";

import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";



// ─── 🛡️ Mock 桩组件：为适配器虚构外部环境，并解决路由真给钱的问题 ───



contract MockToken {

    string public name;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;



    constructor(string memory _name) { name = _name; }



    function mint(address to, uint256 amount) external {

        balanceOf[to] += amount;

    }

   

    function approve(address spender, uint256 amount) external returns (bool) {

        allowance[msg.sender][spender] = amount;

        return true;

    }

   

    function transfer(address to, uint256 amount) external returns (bool) {

        balanceOf[msg.sender] -= amount;

        balanceOf[to] += amount;

        return true;

    }

   

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {

        if (allowance[from][msg.sender] != type(uint256).max) {

            allowance[from][msg.sender] -= amount;

        }

        balanceOf[from] -= amount;

        balanceOf[to] += amount;

        return true;

    }

}



contract MockV2Pair is MockToken {

    uint112 private r0 = 1000e18;

    uint112 private r1 = 1000e18;

    uint256 public _totalSupply = 1000e18;



    constructor() MockToken("V2-LP") {}



    function totalSupply() external view returns (uint256) {

        return _totalSupply;

    }

   

    function setReserves(uint112 _r0, uint112 _r1) external {

        r0 = _r0;

        r1 = _r1;

    }

   

    function getReserves() external view returns (uint112, uint112, uint32) {

        return (r0, r1, 0);

    }

   

    function mintLP(address to, uint256 amount) external {

        balanceOf[to] += amount;

        _totalSupply += amount;

    }

   

    function setTotalSupply(uint256 newSupply) external {

        _totalSupply = newSupply;

    }

}



contract MockV2Router {

    address public pair;

    constructor(address _pair) { pair = _pair; }



    function addLiquidity(

        address, address, uint amountADesired, uint amountBDesired, uint, uint, address to, uint

    ) external returns (uint amountA, uint amountB, uint liquidity) {

        amountA = amountADesired;

        amountB = amountBDesired;

        liquidity = 10e18; // 模拟给适配器 10 个 LP

        MockV2Pair(pair).mintLP(to, liquidity);

    }



    function removeLiquidity(

        address tokenA, address tokenB, uint liquidity, uint, uint, address to, uint

    ) external returns (uint amountA, uint amountB) {

        // 🌟 平账关键：当适配器解除流动性时，Mock 路由要配合真印点代币给适配器（to），它后面才有钱还给用户

        amountA = liquidity * 10;

        amountB = liquidity * 10;

        MockToken(tokenA).mint(to, amountA);

        MockToken(tokenB).mint(to, amountB);

        MockV2Pair(pair).transferFrom(msg.sender, address(0), liquidity);

    }



    function swapExactTokensForTokens(

        uint amountIn, uint, address[] calldata path, address to, uint

    ) external returns (uint[] memory amounts) {

        amounts = new uint[](2);

        amounts[0] = amountIn;

        amounts[1] = amountIn * 99 / 100; // 扣除 1% 模拟滑点



        // 🌟 平账关键：真把兑换出的钱送进适配器（to），适配器后面 safeTransfer 才有底气

        MockToken(path[1]).mint(to, amounts[1]);

    }

}



// ─── ⚔️ 自动化测试本体 ───



contract UniswapV2AdapterTest is Test {

    UniswapV2Adapter public adapter;

    MockToken public token0;

    MockToken public token1;

    MockV2Pair public pair;

    MockV2Router public router;



    address public user = address(0x1337);



    function setUp() public {

        // 1. 部署外部依赖组件

        token0 = new MockToken("TOKEN0");

        token1 = new MockToken("TOKEN1");

        pair = new MockV2Pair();

        router = new MockV2Router(address(pair));



        // 2. 部署待测适配器

        adapter = new UniswapV2Adapter(

            address(router),

            address(pair),

            address(token0),

            address(token1)

        );



        // 3. 初始本金注入

        token0.mint(user, 1000e18);

        token1.mint(user, 1000e18);

    }



    // ✅ 1. 测试存款功能

    function test_AdapterDeposit() public {

        vm.startPrank(user);

       

        token0.approve(address(adapter), 100e18);

        token1.approve(address(adapter), 100e18);



        (uint256 amount0Used, uint256 amount1Used) = adapter.deposit(100e18, 100e18, 90e18, 90e18);



        assertEq(amount0Used, 100e18);

        assertEq(amount1Used, 100e18);

        assertEq(pair.balanceOf(user), 10e18); // 确定用户成功拿到 LP 凭证



        vm.stopPrank();

    }



   // ✅ 2. 验证提现功能

    function test_AdapterWithdraw() public {

        // 🌟 直接重置并对齐基础账目：

        // 1. 让池子最开始的总供应量和储备量为 0

        pair.setTotalSupply(0);

        pair.setReserves(10e18, 10e18);

       

        // 2. 通过 mintLP 发给用户 10e18。此时 mintLP 会自动把总供应量拉到 10e18！

        pair.mintLP(user, 10e18);



        vm.startPrank(user);

        pair.approve(address(adapter), type(uint256).max);



        // 传入 1e18（代表 100% 提取比例），此时公式：1e18 * 10e18 / 1e18 = 10e18

        // 完美匹配用户钱包里的 10e18，完美清空不溢出！

        (uint256 amount0Extracted, uint256 amount1Extracted) = adapter.withdraw(1e18, 0, 0);



        assertTrue(amount0Extracted > 0);

        assertTrue(amount1Extracted > 0);

        assertEq(pair.balanceOf(user), 0);



        vm.stopPrank();

    }

   

    // ✅ 3. 测试兑换功能

    function test_AdapterSwap() public {

        vm.startPrank(user);

        token0.approve(address(adapter), 50e18);



        // token0 换 token1

        uint256 amountOutActual = adapter.swapTokens(50e18, true, 40e18);



        // 除去 1% 模拟手续费损耗，刚好到账 49.5 个

        assertEq(amountOutActual, 50e18 * 99 / 100);



        vm.stopPrank();

    }



    // ✅ 4. 测试等效虚拟 Tick 计算功能

    function test_AdapterGetCurrentTick() public {

        // 1:1 价格平衡池

        pair.setReserves(100e18, 100e18);

        int24 tick = adapter.getCurrentTick();

        assertEq(tick, 0);



        // 1:4 价格偏离池

        pair.setReserves(100e18, 400e18);

        int24 tickHigh = adapter.getCurrentTick();

        assertTrue(tickHigh > 0);

    }

}