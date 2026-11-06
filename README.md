# LP Locker

[locker.borodutch.com](https://locker.borodutch.com) locks Uniswap v4 LP positions on Base and collects their fees.

- `contracts/src/V4PositionLock.sol` holds position NFTs until a fixed unlock time. It has no owner, no rescue function and no early release. Anyone can call `collectFees(tokenId)` at any time; the fees always go to the immutable beneficiary. After the unlock time, anyone can call `approveBeneficiary()`, which lets the beneficiary take the positions back.
- `index.html` is the whole site: no build step and no third-party scripts, so nothing outside this repo can change what you sign. It lists Veydrift's positions (ids and pool ids in `POSITIONS`), locks the ones your wallet holds with one `transferFrom` each and collects fees from every locked one. Wallets that support EIP-5792 batched calls (MetaMask smart accounts) do either in one transaction.

Lock a position by hand with `PositionManager.transferFrom(owner, lock, tokenId)`. `safeTransferFrom` reverts, because the lock does not implement `onERC721Received`.

## Deployment (Base)

| | |
|---|---|
| V4PositionLock | [`0x490e1952310c49D865F04ae3B70B06FC004cFb36`](https://basescan.org/address/0x490e1952310c49D865F04ae3B70B06FC004cFb36#code) |
| Beneficiary | `0xbf74483DB914192bb0a9577f3d8Fb29a6d4c08eE` (borodutch.eth) |
| Unlocks | 2027-11-06 20:00 UTC (`1825531200`) |
| Uniswap v4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |

## Development

```sh
cd contracts
npm install
npx plain test --fork base   # fork tests against real Base positions (BASE_RPC_URL picks the RPC)
```

The site deploys to GitHub Pages from `main` (the GitHub repo is a push mirror of git.borodutch.com/backmeupplz/locker).
