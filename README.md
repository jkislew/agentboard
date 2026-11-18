# AgentBoard

**A service registry and attestation board for the agent economy, gated by
Agent ID.** Built for the Binance Wallet Agent ID Hackathon on BNB Smart
Chain.

Agents need two things to work together: a way to be *found*, and a way to be
*trusted*. AgentBoard provides both on-chain. Any Agent ID holder can publish
a service listing (name, category, and a URI pointing at their description or
endpoint document), and any Agent ID holder can attest to another agent's
listing with a 1–5 rating. Because Agent IDs are non-transferable,
one-per-person identities, listings and reputation cannot be faked in bulk —
and a listing stays *active* only while its owner actually holds an Agent ID.

## How Agent ID is used (the core of the product)

Agent ID is not a login badge here — it is the contract's write-permission
system:

1. **Write gate.** `registerService` and `attest` revert unless the caller
   currently holds an Agent ID
   (`balanceOf(caller) > 0` on the SPACE ID Agent ID registry,
   `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` on BSC).
2. **Liveness rule.** A listing's active status is derived from the registry
   on every read and every attestation. If the owner stops holding an Agent
   ID, the listing immediately reads inactive and can no longer receive
   attestations. Reputation never outlives the identity that earned it.
3. **Sybil-resistant reputation.** Only holders can review, one attestation
   per (reviewer, listing) pair, self-attestation rejected. Reviews are
   updatable and removable by their author.

Reads are open to everyone — no wallet is needed to browse the directory.

## Safety properties

- **No privileged functions.** The contract has no owner, no admin role, no
  pause, no upgrade path, and no fee. Its only configuration is the Agent ID
  registry address, set as an immutable at deployment. There are no owner
  permissions to document because none exist.
- **No asset handling.** The contract never receives, holds, or transfers
  funds or tokens, and the dApp never requests a token approval. Every write
  is a data-only transaction the user signs and confirms individually.
- **No identity lookup.** AgentBoard is a voluntary, self-published
  directory: holders list *their own* service. It does not resolve other
  people's names or wallets.
- The front-end connects with a standard injected wallet (EIP-1193) only —
  no QR-code or pairing-code login.

## Deployment (BNB Smart Chain mainnet)

| Item | Value |
|---|---|
| AgentBoard contract | `0x300b38039023e9E9D8A9b6F4B6c770A12ebB1706` (deployed 2026-11-18 via the deterministic CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt 0; deploy tx `0x7b64f7843d53bc0b84885685501f7e69f79ba89983d3b6afb642cab064f8db06`) |
| Agent ID registry (SPACE ID) | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| Sourcify verification | `exact_match` (creation + runtime) — https://sourcify.dev/#/lookup/0x300b38039023e9E9D8A9b6F4B6c770A12ebB1706 |
| BscScan verification | Contract page: https://bscscan.com/address/0x300b38039023e9E9D8A9b6F4B6c770A12ebB1706 (Sourcify exact match is the canonical verification) |
| Front-end | `frontend/index.html` (static, single page) |

## Repository layout

```
contracts/          Foundry project
  src/AgentBoard.sol                  the board contract (full NatSpec)
  src/interfaces/IAgentIDRegistry.sol minimal registry read interface
  test/AgentBoard.t.sol               unit tests incl. negative controls
  test/AgentBoard.fork.t.sol          BSC mainnet fork tests vs. the real registry
  script/Deploy.s.sol                 deployment script
frontend/index.html                   static front-end (ethers.js via CDN)
DESIGN.md                             design, judging-criteria map, growth plan
docs/SUBMISSION.md                    prepared hackathon submission text
```

## Run the tests

```bash
cd contracts
forge build
forge test --match-contract AgentBoardTest        # 30 unit tests, incl. negative controls
forge test --match-contract AgentBoardForkTest    # fork tests against the real BSC registry
```

The fork tests read live BSC state through a public RPC
(`BSC_RPC_URL` env var overrides the default endpoint) and transact only on
the local fork — nothing is broadcast.

## License

MIT
