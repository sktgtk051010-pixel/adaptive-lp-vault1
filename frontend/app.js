const VAULT_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function deposit(uint256,uint256,uint256,uint256) external",
  "function withdraw(uint256,uint256,uint256) external",
  "function pause() external",
  "function unpause() external",
  "function setVenueAdapter(address) external",
  "function setBountyConfig(uint256,uint256) external",
  "function setCooldownTiers((uint24,uint32)[]) external"
];

const ERC20_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)"
];

const elements = {
  connectBtn: document.getElementById("connectBtn"),
  loadBtn: document.getElementById("loadBtn"),
  depositBtn: document.getElementById("depositBtn"),
  withdrawBtn: document.getElementById("withdrawBtn"),
  vaultAddress: document.getElementById("vaultAddress"),
  vaultInfo: document.getElementById("vaultInfo"),
  status: document.getElementById("status"),
  amount0: document.getElementById("amount0"),
  amount1: document.getElementById("amount1"),
  min0: document.getElementById("min0"),
  min1: document.getElementById("min1"),
  shares: document.getElementById("shares"),
  withdrawMin0: document.getElementById("withdrawMin0"),
  withdrawMin1: document.getElementById("withdrawMin1")
};

const SEPOLIA_CHAIN_ID = "0xAA36A7";

const state = {
  provider: null,
  signer: null,
  signerAddress: null,
  vault: null,
  token0: null,
  token1: null,
  decimals0: 18,
  decimals1: 18
};

function setStatus(message, isError = false) {
  elements.status.textContent = message;
  elements.status.classList.toggle("error", isError);
}

function shortAddress(address) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

function getVaultAddress() {
  const value = elements.vaultAddress.value.trim();
  if (!value) {
    throw new Error("Please enter a vault address.");
  }
  if (!ethers.isAddress(value)) {
    throw new Error("The vault address is invalid.");
  }
  return value;
}

async function ensureSepoliaNetwork() {
  if (!window.ethereum) {
    throw new Error("Install MetaMask or another Ethereum wallet provider.");
  }

  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: SEPOLIA_CHAIN_ID }]
    });
  } catch (error) {
    if (error.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: SEPOLIA_CHAIN_ID,
          chainName: "Sepolia",
          nativeCurrency: { name: "Sepolia Ether", symbol: "SEP", decimals: 18 },
          rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"],
          blockExplorerUrls: ["https://sepolia.etherscan.io"]
        }]
      });
    } else {
      throw error;
    }
  }
}

async function connectWallet() {
  if (!window.ethereum) {
    setStatus("Install MetaMask or another Ethereum wallet provider.", true);
    return;
  }

  try {
    await ensureSepoliaNetwork();
    const provider = new ethers.BrowserProvider(window.ethereum);
    const accounts = await provider.send("eth_requestAccounts", []);
    const signer = await provider.getSigner();

    state.provider = provider;
    state.signer = signer;
    state.signerAddress = accounts[0];

    elements.connectBtn.textContent = `Connected: ${shortAddress(state.signerAddress)}`;
    setStatus(`Connected as ${state.signerAddress}`);

    if (elements.vaultAddress.value) {
      await loadVault();
    }
  } catch (error) {
    setStatus(error.message || "Wallet connection failed.", true);
  }
}

async function loadVault() {
  try {
    const vaultAddress = getVaultAddress();
    const provider = state.provider || new ethers.BrowserProvider(window.ethereum);
    state.provider = provider;

    const vault = new ethers.Contract(vaultAddress, VAULT_ABI, provider);
    const [name, symbol, token0Address, token1Address, owner, paused, supply] = await Promise.all([
      vault.name(),
      vault.symbol(),
      vault.token0(),
      vault.token1(),
      vault.owner(),
      vault.paused(),
      vault.totalSupply()
    ]);

    const token0 = new ethers.Contract(token0Address, ERC20_ABI, provider);
    const token1 = new ethers.Contract(token1Address, ERC20_ABI, provider);
    const [dec0, dec1, sym0, sym1] = await Promise.all([
      token0.decimals().catch(() => 18),
      token1.decimals().catch(() => 18),
      token0.symbol().catch(() => "TOKEN0"),
      token1.symbol().catch(() => "TOKEN1")
    ]);

    state.vault = vault;
    state.token0 = token0;
    state.token1 = token1;
    state.decimals0 = Number(dec0);
    state.decimals1 = Number(dec1);

    elements.vaultInfo.innerHTML = `
      <p><strong>Name:</strong> ${name}</p>
      <p><strong>Symbol:</strong> ${symbol}</p>
      <p><strong>Token 0:</strong> ${sym0} (${shortAddress(token0Address)})</p>
      <p><strong>Token 1:</strong> ${sym1} (${shortAddress(token1Address)})</p>
      <p><strong>Owner:</strong> ${shortAddress(owner)}</p>
      <p><strong>Paused:</strong> ${paused ? "Yes" : "No"}</p>
      <p><strong>Total supply:</strong> ${ethers.formatUnits(supply, 18)}</p>
    `;

    setStatus(`Loaded vault ${name} (${symbol})`);
  } catch (error) {
    setStatus(error.message || "Vault loading failed.", true);
  }
}

async function ensureAllowance(token, spender, amount) {
  if (!state.signerAddress) {
    throw new Error("Connect a wallet before depositing.");
  }

  const allowance = await token.allowance(state.signerAddress, spender);
  if (allowance >= amount) {
    return;
  }

  const tx = await token.approve(spender, ethers.MaxUint256);
  await tx.wait();
}

async function deposit() {
  try {
    if (!state.signer) {
      throw new Error("Connect a wallet first.");
    }

    const vaultAddress = getVaultAddress();
    const vaultWithSigner = new ethers.Contract(vaultAddress, VAULT_ABI, state.signer);
    const amount0 = ethers.parseUnits(elements.amount0.value || "0", state.decimals0);
    const amount1 = ethers.parseUnits(elements.amount1.value || "0", state.decimals1);
    const min0 = ethers.parseUnits(elements.min0.value || "0", state.decimals0);
    const min1 = ethers.parseUnits(elements.min1.value || "0", state.decimals1);

    if (amount0 <= 0n || amount1 <= 0n) {
      throw new Error("Deposit amounts must be greater than zero.");
    }

    await ensureAllowance(state.token0, vaultAddress, amount0);
    await ensureAllowance(state.token1, vaultAddress, amount1);

    const tx = await vaultWithSigner.deposit(amount0, amount1, min0, min1);
    setStatus("Deposit submitted. Waiting for confirmation...");
    await tx.wait();
    setStatus("Deposit confirmed.");
  } catch (error) {
    setStatus(error.message || "Deposit failed.", true);
  }
}

async function withdraw() {
  try {
    if (!state.signer) {
      throw new Error("Connect a wallet first.");
    }

    const vaultAddress = getVaultAddress();
    const vaultWithSigner = new ethers.Contract(vaultAddress, VAULT_ABI, state.signer);
    const shares = ethers.parseUnits(elements.shares.value || "0", 18);
    const min0 = ethers.parseUnits(elements.withdrawMin0.value || "0", state.decimals0);
    const min1 = ethers.parseUnits(elements.withdrawMin1.value || "0", state.decimals1);

    if (shares <= 0n) {
      throw new Error("Shares must be greater than zero.");
    }

    const tx = await vaultWithSigner.withdraw(shares, min0, min1);
    setStatus("Withdraw submitted. Waiting for confirmation...");
    await tx.wait();
    setStatus("Withdraw confirmed.");
  } catch (error) {
    setStatus(error.message || "Withdraw failed.", true);
  }
}

const contractParam = new URLSearchParams(window.location.search).get("contract");
if (contractParam) {
  elements.vaultAddress.value = contractParam;
}

window.addEventListener("load", () => {
  if (contractParam) {
    setStatus(`Vault prefilled. Connect wallet to continue.`);
  }
});

elements.connectBtn.addEventListener("click", connectWallet);
elements.loadBtn.addEventListener("click", loadVault);
elements.depositBtn.addEventListener("click", deposit);
elements.withdrawBtn.addEventListener("click", withdraw);
