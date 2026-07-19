# 1971 — Good as Gold

A stablecoin that acts like gold, priced like math. Live on Robinhood Chain mainnet.

**Site:** [1971fi.com](https://1971fi.com) · **X:** [@1971Fi](https://x.com/1971Fi) · **Explorer:** [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com/address/0x18fa6c4f8000ba5910b132825ab4de4819209f1c)

## The mechanism

Three legs, all in cash:

1. **BACKED** — a 4% fee on every swap (both directions, taken in ETH by a Uniswap v4 hook) routes 60% into a USDG redemption reserve. The backing only grows.
2. **YIELDING** — the other 40% accrues to holders as claimable USDG. No emissions, no staking, no inflation: trading fees or nothing.
3. **REDEEMABLE** — burn 1971, receive your pro-rata share of the reserve at NAV. Supply only shrinks. The floor per token never decreases from a redemption (test-enforced invariant; neutral at full maturity, strictly accretive on early redemption).

Plus a permissionless discount buy-and-burn when market price falls below NAV.

## Deployed contracts (Robinhood Chain, 4663)

All source verified on Blockscout.

| Contract | Address |
|---|---|
| GoodAsGold (1971) | `0x18fa6c4f8000ba5910b132825ab4de4819209f1c` |
| RedemptionVault | `0xf0d25cb1eb84e46de3e813db0003b5ceb5f056b0` |
| FeeVault | `0x8bbb046cb1165a9b425ae91d754a3497f5ee4231` |
| TTPFeeHook (4%) | `0xf5aeed6f2be9bf5c36ef53d3e2a81e92468f40cc` |
| BuybackEngine | `0x91ef9b09fa009d422b1d51f6a7a463b439ade8ce` |
| GagDistributor | `0xe8d0cc92bdc8e08a6fba90f74d9d1da6af4e261b` |
| DiscountSwapper | `0x779ae42e06c73174983362d62aae191d52ae08b2` |
| DiscountRouter | `0x9e04f0eecd5feb818aa307f54e7edaa8c823e8c3` |
| PegFeed ($1.00) | `0x0cdc0b0042cbd2f9f44685b1c8c5f97e237085a8` |
| LpLocker | `0x18438c5163bd5cf85547ba56fac261ff3a2af659` |
| VestingLocker | `0xA4281774Ce1836eC24993D81DDE429d15f30B6FE` |
| USDG (canonical) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

## Supply, fully accounted

Genesis mint 1,000,000,000. 350M burned at genesis; the developer has since burned another
7M through the redemption window at the published early-exit haircut. Circulating: **643,000,000**.

| Bucket | Amount | % of circulating | Where |
|---|---|---|---|
| Market (pool + ask wall) | 503M | 78.2% | PoolManager, positions held by LpLocker |
| Developer allocation, vested | 100M | 15.6% | VestingLocker: immutable, 3-month cliff, 12-month linear, earns no yield |
| Developer payment, liquid | 40M | 6.2% | Creator wallet `0x008baC045a4220Bf6755564C5eA2e1B271EB670F` — payment for building and open-sourcing this protocol, disclosed here rather than hidden; 7M of the original 47M already burned |
| Burned | 357M | — | 350M at genesis (totalSupply reduction) + 7M redeemed by the developer (dead address); the floor divides by circulating supply, which only shrinks |

Developer liquid at the deployer address: **0**. Every creator revenue stream (redemption fee 1%, 50% of early-redemption forfeitures, LP fees) is disclosed at [1971fi.com](https://1971fi.com) under Docs.

## Verify it yourself

```sh
# the floor, straight from the chain — no website required
cast call 0xf0d25cb1eb84e46de3e813db0003b5ceb5f056b0 "navPerToken()(uint256)" --rpc-url https://rpc.mainnet.chain.robinhood.com
cast call 0xf0d25cb1eb84e46de3e813db0003b5ceb5f056b0 "nav()(uint256)" --rpc-url https://rpc.mainnet.chain.robinhood.com
```

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
npm install          # vendored Uniswap v4 core + periphery
forge build
forge test -vv       # 26 unit tests + NAV invariant suite; fork tests need RH_RPC set
```

## Security posture

Unaudited. Covered by the public test suite, fork tests against live pools, and the on-chain NAV invariant. The contracts are the authority; if anything else conflicts with them, the contracts win. Use only funds you can afford to lose. Not affiliated with Robinhood Markets, Paxos, Uniswap, or Chainlink.

## License

MIT
