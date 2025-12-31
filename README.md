# Custom Fee Anti-MEV Hook (Uniswap v4)

CustomFeeAntiMevHook is a Uniswap v4 hook that targets TOKEN/ETH or TOKEN/WETH pools (exactly one side is native or wrapped native). It overrides LP fees per swap direction (buy vs sell) and can optionally enforce anti-MEV rules such as blacklisting, cooldown/one-trade-per-block, max sell amount, and router-verified swapper resolution.

## Hook Behavior

-   Eligible pools: TOKEN/ETH or TOKEN/WETH only (exactly one side is native or wrapped native).
-   Fee override: buy and sell fees can be set independently per pool.
-   Protection options (per pool):
    -   blacklist
    -   cooldown seconds
    -   one-trade-per-block
    -   max sell amount
    -   verified router swapper resolution
-   Pool-level settings can be modified only by the target token owner via `Ownable(token).owner()`.
-   Target tokens must implement `owner()` (Ownable) to be functional; non-ownable tokens are treated as unsupported by the hook.
-   If the target token renounces ownership (owner == address(0)), the hook clears the target token for that pool and disables hook behavior for it.
-   Unsupported pools: hook no-ops and leaves default fee of 3000 bps (0.3%).

## Configuration

Foundry config lives in `foundry.toml`. Optimizer is enabled with 44,444,444 runs.

RPC endpoints are read from environment variables:

-   `LOCALHOST_URL`
-   `SEPOLIA_RPC_URL`
-   `ETHEREUM_RPC_URL`

## Deployment

The unified script deploys the hook via CREATE2 at a flagged address using `HookMiner`, with per-network settings loaded from JSON.

Env vars (optional):

-   `PRIVATE_KEY`
-   `CONFIG_PATH` (defaults to mainnet or sepolia config based on `block.chainid`)

Example (Sepolia):

```bash
forge script script/DeployCustomFeeHookedV4Pool.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Example (Mainnet):

```bash
forge script script/DeployCustomFeeHookedV4Pool.s.sol \
  --rpc-url $ETHEREUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Deploy config files:

-   `deploy-config/CustomFeeAntiMevHook.mainnet.json`
-   `deploy-config/CustomFeeAntiMevHook.sepolia.json`

Config fields:

-   `chainId`
-   `poolManager`
-   `wrappedNative`
-   `create2Deployer`
-   `owner`

## Tests

```bash
forge test test/CustomFeeAntiMevHook.t.sol
```
