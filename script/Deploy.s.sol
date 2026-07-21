// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AdaptiveIPVault} from "../src/AdaptiveIPVault.sol";
import {TWAPOracle} from "../src/TWAPOracle.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";

contract DeployScript is Script {
    function run() public {
        string memory vaultName = vm.envOr("VAULT_NAME", string("Adaptive LP Vault"));
        string memory vaultSymbol = vm.envOr("VAULT_SYMBOL", string("ALP"));
        address token0 = vm.envOr("TOKEN0", address(0));
        address token1 = vm.envOr("TOKEN1", address(0));
        address vaultBaseToken = vm.envOr("VAULT_BASE_TOKEN", token0);
        address oracleTarget = vm.envOr("ORACLE_TARGET", address(0));
        bool oracleIsV3 = vm.envOr("ORACLE_IS_V3", true);
        uint32 twapPeriod = uint32(vm.envOr("TWAP_PERIOD", uint256(1800)));
        uint32 fastTwapPeriod = uint32(vm.envOr("FAST_TWAP_PERIOD", uint256(300)));
        uint256 premiumMultiplierBps = vm.envOr("PREMIUM_MULTIPLIER_BPS", uint256(11000));
        uint256 maxRewardLimit = vm.envOr("MAX_REWARD_LIMIT", uint256(100e18));

        require(token0 != address(0) && token1 != address(0), "TOKEN0/TOKEN1 must be set");
        require(oracleTarget != address(0), "ORACLE_TARGET must be set");

        vm.startBroadcast();

        address adapter;
        string memory adapterType = vm.envOr("ADAPTER_TYPE", string("v3"));
        if (keccak256(bytes(adapterType)) == keccak256(bytes("v2"))) {
            address router = vm.envOr("ROUTER", address(0));
            address pair = vm.envOr("PAIR", address(0));
            require(router != address(0) && pair != address(0), "V2 adapter addresses must be set");
            UniswapV2Adapter v2Adapter = new UniswapV2Adapter(router, pair, token0, token1);
            adapter = address(v2Adapter);
        } else {
            address positionManager = vm.envOr("POSITION_MANAGER", address(0));
            address pool = vm.envOr("POOL", address(0));
            address router = vm.envOr("ROUTER", address(0));
            require(positionManager != address(0) && pool != address(0) && router != address(0), "V3 adapter addresses must be set");
            UniswapV3Adapter v3Adapter = new UniswapV3Adapter(positionManager, pool, router);
            adapter = address(v3Adapter);
        }

        TWAPOracle oracle = new TWAPOracle(oracleTarget, vaultBaseToken, oracleIsV3, twapPeriod, fastTwapPeriod);
        AdaptiveIPVault vault = new AdaptiveIPVault(
            vaultName,
            vaultSymbol,
            token0,
            token1,
            adapter,
            address(oracle),
            vaultBaseToken,
            premiumMultiplierBps,
            maxRewardLimit
        );

        vm.stopBroadcast();

        console.log("Adapter deployed at:", adapter);
        console.log("Oracle deployed at:", address(oracle));
        console.log("Vault deployed at:", address(vault));
    }
}
