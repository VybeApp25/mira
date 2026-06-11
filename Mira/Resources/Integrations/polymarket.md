# Polymarket
tool: run_python_skill
access: read-only (no trading)

## When to use
User says: Polymarket, prediction market, odds, probability, bet, market, will X happen, what are the odds of, forecast.

## Ops

### Trending markets (default)
`run_python_skill(skill:"polymarket", args:{op:"trending", limit?:10})`
Returns top markets by 24h volume. Each market: question, outcomes with % probability, 24h volume, end date, URL.

### Search markets
`run_python_skill(skill:"polymarket", args:{op:"search", query:"<topic>", limit?:5})`

### Market detail by slug
`run_python_skill(skill:"polymarket", args:{op:"detail", slug:"<market-slug>"})`
Slug is the URL path component, e.g. "will-trump-win-2024".

## Canonical patterns

### "What does Polymarket say about <topic>?"
op:"search", query:"<topic>" → list outcomes with probabilities.

### "What are the current prediction markets?"
op:"trending", limit:10 → table of top markets.

### "What are the odds of <specific event>?"
op:"search" → find matching market → show probabilities.

## Presentation
- Present probabilities as percentages: "Yes: 67.4%, No: 32.6%"
- Include market end date and Polymarket URL for each market
- Always note: these are prediction market prices, not guaranteed outcomes
- Never place or suggest placing trades on behalf of the user
