---
name: update-azure-openai-prices
description: Refresh the hard-coded Azure OpenAI per-token rates in litellm-config.yaml and CLAUDE.md from Azure's public retail price feed. Use this whenever the user mentions Azure prices, token prices, price drift, cost tracking, spend figures being wrong, a model repricing, or moving the Azure deployment to a different region or deployment type — and also when they just ask to "check the prices" or report that the LiteLLM GUI or statusline cost numbers look too high or too low. Also use it after any change to the model_list in linux/configs/litellm-config.yaml, since a newly added model ships with no rates at all.
---

# Update Azure OpenAI prices

## Why this exists

`linux/configs/litellm-config.yaml` routes every deployment as `openai/gpt-…`,
which is load-bearing for the Anthropic→Responses adapter. That prefix also
drives cost lookup, so without an override LiteLLM bills **OpenAI list prices**
for traffic Azure actually invoices. Both the LiteLLM GUI cost columns and
`statusline.sh`'s spend figures read the resulting spend-logs table, so both go
wrong together.

The override is an explicit per-token rate set under each deployment's
`model_info`. Those rates are **hand-maintained — nothing refreshes them**,
which is what this skill is for.

**Do not "fix" this by switching to `model_info.base_model`.** It looks right
and silently does nothing: `_select_model_name_for_cost_calc` returns the
`azure/eu/…` key, but the lookup one layer down passes the route's provider
with it, and `get_model_info("azure/eu/gpt-5.6-luna", custom_llm_provider="openai")`
raises `This model isn't mapped yet` because that entry's `litellm_provider` is
`azure`. The cost calculator swallows the exception and falls back to the OpenAI
entry. `base_model` only works when the key's provider matches the route's.

## Step 1 — read the current rates

`scripts/fetch_azure_prices.py` queries `prices.azure.com`, which is public and
needs no auth. Use it rather than the Azure pricing web page, which renders its
price cells client-side and returns `$-` to a plain fetch.

```bash
python3 .claude/skills/update-azure-openai-prices/scripts/fetch_azure_prices.py \
  --config linux/configs/litellm-config.yaml
```

It reads the model list straight from the config, so a newly added tier is
picked up with no argument changes. Defaults are `--region swedencentral
--scope DZ`, matching today's deployment (Data Zone Standard, EU zone — Sweden
Central sits inside the Azure EU Data Boundary). Pass `--scope Gl` for Global
Standard, `--region <name>` for another region.

| Exit | Meaning | What to do |
|---|---|---|
| `0` | in sync | Stop and report prices unchanged. A no-op diff wastes the user's review attention. |
| `1` | drift | Go to Step 2. |
| `2` | a meter was missing | Azure may not sell that model, or the id may not follow `gpt-<family>-<tier>`. Report which model and stop — never guess a rate. |

## Step 2 — apply the new rates

Only when Step 1 reported drift. Everything lives in
`linux/configs/litellm-config.yaml`; `CLAUDE.md` deliberately holds no figures,
so leave it alone unless the *mechanism* changed.

**1. The rate blocks.** Each deployment's `model_info` holds the six keys, which
the script prints per model in the exact order and float format the file uses —
paste them as printed rather than retyping, since a transposed exponent here is
invisible until someone reads a bill.

**2. The `$/1M` table** in the comment block above `model_list`
(`grep -n 'Verified' linux/configs/litellm-config.yaml` lands in it). The
script's `$/1M` line per model is already in that table's column order
(in / cached-in / out), which is *not* the order of the YAML keys. Also update
the `Verified …` date to today and, in the reprice-watch note lower in the
block, the meter date that counts as "unchanged".

If Azure has finally matched an OpenAI price cut, delete the notes saying it had
*not*. A stale explanation is worse than none, because the next reader trusts it.

## Step 3 — verify

Re-run the Step 1 command. It should now print `IN SYNC` and exit `0`. That
compares the file you just edited against the live feed, so it catches a typo'd
exponent or a block pasted under the wrong tier.

Then check the YAML still parses:

```bash
python3 -c 'import yaml;yaml.safe_load(open("linux/configs/litellm-config.yaml"))'
```

On a box with the proxy running, a real request's `x-litellm-response-cost`
header confirms it end-to-end after `update-ct-kali-llm` — but that spends a
live API call to re-check what the feed diff already covered, so offer it rather
than run it by default.

## Reporting back

Lead with whether anything changed, then the per-model deltas as ratios — a
ratio tells the user what happens to their bill in a way six raw floats do not.
Name the meter date, since that is the evidence for "this is current". Mention
that existing spend-log rows are **not** recomputed, so the GUI's daily and
30-day figures stay blended for about a month after a change.

Commit only if the user asks.
