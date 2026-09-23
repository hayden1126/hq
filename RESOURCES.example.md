# Resources

Cloud accounts, credits, and subscriptions hq tracks, the way `REGISTRY.md` maps projects and
`SOURCES.md` maps external sources. Inward operational state (account IDs, balances, expiry,
application status) for running the projects, never career material: it does not flow to the
vault, a CV, or the public site. This is the example; the real file is `RESOURCES.md`, gitignored
because it names account IDs and balances. Seed only verified details; never guess a balance.

Fields:
- `kind`: `cloud-credit` | `api-credit` | `subscription`.
- `provider`: the vendor (AWS, Anthropic, ...).
- `account`: for cloud credits, the account the resource attaches to (id + root email).
- `entity`: the company/domain the account is registered under, when it matters for a program.
- `program` / `plan`: the credit program or subscription plan (with Org ID for referral programs).
- `amount`: credit value or subscription cost; note if it varies or is unconfirmed.
- `status`: `active` | `pending` | `expired`, with the key date.
- `funds`: which project(s) this pays for; link the registry path.
- `caveat`: anything that bites (billing traps, do-not-launch conditions, renewal autopay).
- `expires` / `renews`: the date that matters.

## example-cloud-credit
- kind: cloud-credit
- provider: AWS
- account: 0000-0000-0000 (root email you@yourdomain.dev)
- entity: your-company (yourdomain.dev)
- program: AWS Activate, Portfolio tier, via <accelerator> (Org ID XXXXX)
- amount: varies by org; confirm when credits post
- status: pending NN-business-day review (applied YYYY-MM-DD)
- funds: code/<project>
- caveat: do not launch instances until credits post, or it bills the card
- expires: 2 years from grant
