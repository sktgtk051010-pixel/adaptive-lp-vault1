## Adaptive LP Vault

This repository contains the Solidity vault, oracle, adapters, Foundry tests, and a minimal browser frontend for interacting with a deployed vault on a public testnet.

## Quick start

### 1. Install Foundry

Follow the official Foundry install guide:

https://book.getfoundry.sh/getting-started/installation

### 2. Build and test

```shell
forge build
forge test
```

### 3. Prepare deployment environment

Copy the example environment file and fill in the values for your target network:

```shell
cp .env.example .env
```

Required values:

- `RPC_URL`: RPC URL for Sepolia, Holesky, Base Sepolia, or another EVM testnet
- `PRIVATE_KEY`: your wallet private key for deployment
- `TOKEN0`: address of token 0
- `TOKEN1`: address of token 1
- `VAULT_BASE_TOKEN`: one of the two token addresses
- `ORACLE_TARGET`: address of the liquidity pool or price source used by the oracle

### 4. Deploy to a testnet

```shell
./script/deploy-testnet.sh .env
```

The deploy script will broadcast the adapter, oracle, and vault contracts using the values from your environment file.

### 5. Run the frontend

Serve the frontend directory with any static file server, for example:

```shell
python3 -m http.server 3000 --directory frontend
```

Then open:

```text
http://localhost:3000/?contract=<DEPLOYED_VAULT_ADDRESS>
```

## Frontend notes

The frontend is intentionally minimal and uses ethers.js to connect MetaMask, load a vault contract, and submit deposit/withdraw transactions.

## Contract notes

The core contracts are:

- [src/AdaptiveIPVault.sol](src/AdaptiveIPVault.sol)
- [src/TWAPOracle.sol](src/TWAPOracle.sol)
- [src/adapters/UniswapV2Adapter.sol](src/adapters/UniswapV2Adapter.sol)
- [src/adapters/UniswapV3Adapter.sol](src/adapters/UniswapV3Adapter.sol)

