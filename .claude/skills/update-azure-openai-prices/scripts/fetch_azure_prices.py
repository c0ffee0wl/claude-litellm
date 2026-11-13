#!/usr/bin/env python3
"""Read current Azure OpenAI per-token rates from the public retail price feed.

The feed at prices.azure.com needs no auth and is the authoritative source —
the Azure pricing web page renders its price cells client-side and returns "$-"
to a plain fetch, so scraping it does not work.

Meter names follow a fixed grammar, e.g.

    5.6 luna ShortCo Cd Inp Std DZ 1M Tokens
    │   │    │       │      │   │
    │   │    │       │      │   └─ scope:  Gl (Global Standard) | DZ (Data Zone)
    │   │    │       │      └───── tier:   Std (standard) | PP (priority processing)
    │   │    │       └──────────── kind:   Inp | Opt | Cd Inp (cache read) | Cd Wr (cache write)
    │   │    └──────────────────── context: ShortCo (<=272k) | LongCo (>272k)
    │   └───────────────────────── model tier
    └───────────────────────────── model family

The model prefix is NOT spelled consistently across families: GPT-5.6 uses
`5.6 luna`, but the GPT-6 product mixes `6-astra`, `6.1-sol` and `61 terra` in
one price sheet. meter_prefixes() therefore tries every spelling seen so far;
a family that invents a new one surfaces as exit 2 (missing meter), never as a
guessed rate.

Only the Std meters map into litellm-config.yaml. All eight model_info keys
are managed, including the cache-write pair from the `Cd Wr` meters (Azure
bills cache writes at 1.25x input on both GPT-5.6 and GPT-6). They are stated
even though the Responses API rarely reports cache-creation tokens: omitting
them lets Router._inherit_builtin_cache_pricing copy OPENAI's cache-write rate
onto Azure traffic.

Usage:
    fetch_azure_prices.py --config ../../../linux/configs/litellm-config.yaml
    fetch_azure_prices.py --model gpt-5.6-luna --scope Gl --region eastus2
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request

FEED = "https://prices.azure.com/api/retail/prices"
PREFIXES_PER_REQUEST = 12
API_VERSION = "2023-01-01-preview"

# (context, kind) -> the key litellm-config.yaml uses under model_info, in the
# order the config spells them. Long-context meters carry Azure's >272k tier,
# which LiteLLM names "_above_272k_tokens".
KEY_MAP = {
    ("ShortCo", "Inp"): "input_cost_per_token",
    ("ShortCo", "Opt"): "output_cost_per_token",
    ("ShortCo", "Cd Inp"): "cache_read_input_token_cost",
    ("ShortCo", "Cd Wr"): "cache_creation_input_token_cost",
    ("LongCo", "Inp"): "input_cost_per_token_above_272k_tokens",
    ("LongCo", "Opt"): "output_cost_per_token_above_272k_tokens",
    ("LongCo", "Cd Inp"): "cache_read_input_token_cost_above_272k_tokens",
    ("LongCo", "Cd Wr"): "cache_creation_input_token_cost_above_272k_tokens",
}
KEY_ORDER = list(KEY_MAP.values())

MODEL_RE = re.compile(r"^(?:.*?/)?gpt-(?P<family>[\d.]+)-(?P<tier>.+)$")


def split_model(model_id: str) -> tuple[str, str]:
    """'azure/gpt-5.6-luna' -> ('5.6', 'luna'). Raises on an unparseable id."""
    m = MODEL_RE.match(model_id)
    if not m:
        raise ValueError(
            f"cannot derive family/tier from {model_id!r} — expected gpt-<family>-<tier>"
        )
    return m.group("family"), m.group("tier")


def meter_prefixes(family: str, tier: str) -> tuple[str, ...]:
    """Every meter-name spelling of this model seen in the feed, each ending in a space.

    ('6.1', 'terra') -> '6.1 terra ', '6.1-terra ', '61 terra ', '61-terra '.
    The trailing space keeps '6-sol ' from matching a '6-sol-mini' meter.
    """
    families = dict.fromkeys((family, family.replace(".", "")))
    return tuple(f"{f}{sep}{tier} " for f in families for sep in (" ", "-"))


def fetch_meters(models: set[tuple[str, str]], region: str) -> list[dict]:
    """Fetch every meter for these models in one request.

    The spellings are OR-ed into as few requests as the feed allows: it
    answers 400 once a filter carries ~25 `contains` clauses (seen at 28), so
    they go out in chunks of PREFIXES_PER_REQUEST. A model is ~24 meters and
    the feed pages at 1000, so the inner loop rarely runs twice — it exists for
    correctness, with a page cap so a malformed NextPageLink cannot hang a run.
    """
    prefixes = sorted({p for family, tier in models for p in meter_prefixes(family, tier)})
    items: list[dict] = []
    for i in range(0, len(prefixes), PREFIXES_PER_REQUEST):
        chunk = prefixes[i : i + PREFIXES_PER_REQUEST]
        predicate = " or ".join(f"contains(meterName, '{p}')" for p in chunk)
        odata = f"armRegionName eq '{region}' and ({predicate})"
        url = (
            f"{FEED}?api-version={API_VERSION}&currencyCode=USD"
            f"&$filter={urllib.parse.quote(odata)}"
        )
        for _ in range(50):
            with urllib.request.urlopen(url, timeout=60) as fh:
                page = json.load(fh)
            items.extend(page.get("Items", []))
            url = page.get("NextPageLink")
            if not url:
                break
    return items


def parse_meter(name: str, family: str, tier: str) -> tuple[str, str, str, str] | None:
    """Split a meter name into (context, kind, price_tier, scope), or None."""
    suffix = " 1M Tokens"
    prefix = next((p for p in meter_prefixes(family, tier) if name.startswith(p)), None)
    if prefix is None or not name.endswith(suffix):
        return None
    parts = name[len(prefix) : -len(suffix)].split()
    if len(parts) < 4:
        return None
    context, price_tier, scope = parts[0], parts[-2], parts[-1]
    return context, " ".join(parts[1:-2]), price_tier, scope


def fmt(value: float) -> str:
    """Render a per-token rate the way the config spells it (e.g. 2.75e-06)."""
    return f"{value:.6g}"


def rates_for(model_id: str, family: str, tier: str, items: list[dict], scope: str) -> dict:
    """Pick this model's Std meters out of the shared fetch."""
    per_million: dict[str, float] = {}
    dates: set[str] = set()
    for item in items:
        parsed = parse_meter(item["meterName"], family, tier)
        if not parsed:
            continue
        context, kind, price_tier, meter_scope = parsed
        if price_tier != "Std" or meter_scope != scope:
            continue
        key = KEY_MAP.get((context, kind))
        if key is None:  # a meter shape we deliberately do not map
            continue
        per_million[key] = float(item["retailPrice"])
        dates.add(str(item.get("effectiveStartDate", ""))[:10])

    return {
        "model": model_id,
        "rates": {k: per_million[k] / 1e6 for k in KEY_ORDER if k in per_million},
        "per_million": per_million,
        "effective": sorted(dates),
        "missing": [k for k in KEY_ORDER if k not in per_million],
    }


def models_from_config(path: str) -> list[tuple[str, dict]]:
    """Return [(public model_name, current model_info rates)] from the config."""
    try:
        import yaml
    except ImportError:
        sys.exit(
            "PyYAML is required to read the config (apt install python3-yaml, "
            "or pass --model instead)"
        )
    with open(path) as fh:
        cfg = yaml.safe_load(fh)
    out = []
    for entry in cfg.get("model_list") or []:
        info = entry.get("model_info") or {}
        out.append((entry["model_name"], {k: float(info[k]) for k in KEY_ORDER if k in info}))
    return out


def per_million_line(pm: dict[str, float]) -> str:
    """The $/1M summary for the config's comment table.

    Column order matches that table (in / cached-in / cache-wr / out), which is NOT
    KEY_ORDER — the YAML block groups the cache rate last, the table puts it in
    the middle. Printing them in table order keeps the update a copy, not a
    re-sort, since a silently transposed column is the likeliest slip here.
    """
    def row(suffix: str) -> str:
        keys = (
            f"input_cost_per_token{suffix}",
            f"cache_read_input_token_cost{suffix}",
            f"cache_creation_input_token_cost{suffix}",
            f"output_cost_per_token{suffix}",
        )
        return " / ".join(f"{pm[k]:g}" if k in pm else "?" for k in keys)
    return (
        f"$/1M (in / cached-in / cache-wr / out)  short {row('')}"
        f"   |   >272k {row('_above_272k_tokens')}"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config", help="litellm-config.yaml to read models from and diff against")
    ap.add_argument("--model", action="append", default=[], help="model id, repeatable")
    ap.add_argument("--region", default="swedencentral", help="default: swedencentral")
    ap.add_argument(
        "--scope",
        default="DZ",
        choices=["DZ", "Gl"],
        help="DZ = Data Zone Standard (default), Gl = Global Standard",
    )
    args = ap.parse_args()

    if args.config:
        targets = models_from_config(args.config)
    elif args.model:
        targets = [(m, {}) for m in args.model]
    else:
        ap.error("pass --config or at least one --model")

    problems: list[str] = []
    parsed: dict[str, tuple[str, str]] = {}
    for model_id, _ in targets:
        try:
            parsed[model_id] = split_model(model_id)
        except ValueError as exc:
            problems.append(str(exc))
    if not parsed:
        for problem in problems:
            print(f"WARNING: {problem}", file=sys.stderr)
        return 2

    items = fetch_meters(set(parsed.values()), args.region)

    drifted = []
    for model_id, current in targets:
        if model_id not in parsed:
            continue  # already reported above
        res = rates_for(model_id, *parsed[model_id], items, args.scope)
        if res["missing"]:
            problems.append(f"{model_id}: no meter for {', '.join(res['missing'])}")
        changes = {
            k: (current.get(k), v)
            for k, v in res["rates"].items()
            if current.get(k) is None or abs(current[k] - v) > 1e-15
        }
        if changes and current:
            drifted.append(model_id)

        print(f"=== {res['model']}  ({args.scope} @ {args.region}, "
              f"meters effective {', '.join(res['effective']) or 'unknown'})")
        print(f"  {per_million_line(res['per_million'])}")
        for key, value in res["rates"].items():
            print(f"      {key}: {fmt(value)}")
        if current:
            if changes:
                print("  DRIFT:")
                for k, (old, new) in changes.items():
                    print(f"    {k}: {fmt(old) if old is not None else '(absent)'} -> {fmt(new)}")
            else:
                print("  in sync with config")
        print()

    for problem in problems:
        print(f"WARNING: {problem}", file=sys.stderr)
    if args.config:
        print(f"DRIFT ({', '.join(drifted)})" if drifted else "IN SYNC")

    if problems:
        return 2
    return 1 if drifted else 0


if __name__ == "__main__":
    sys.exit(main())
