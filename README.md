# Portfolio Analysis

This repo has two main scripts:

- `pull_info.py` updates a holdings CSV with current market values from Yahoo Finance
- `agent.py` runs a Microsoft Agent Framework client against your Foundry models and can classify holdings in the CSV

## Setup

Install dependencies with:

```bash
uv sync
```

The agent script expects a populated `.env` file with your Foundry endpoint and service principal credentials.

## CSV Format

The holdings CSV is expected to use this schema:

```csv
ticker,num_shares,broker,type
```

After `pull_info.py` runs, the file is rewritten with:

```csv
ticker,num_shares,broker,type,value
```

After `agent.py --classify-csv` runs, the file is rewritten with:

```csv
ticker,num_shares,broker,type,value,classification
```

`data.csv` in this repo is mock data for safe sharing. Keep real holdings in a local file such as `nikhil-data.csv` (ignored by Git) and run scripts with `--source` or `--classify-csv` pointing to that file.

## `pull_info.py`

`pull_info.py` reads a CSV, fetches current prices from Yahoo Finance, overwrites the `value` column with fresh data, and prints totals grouped by broker and account type.

### Default usage

If no path is supplied, it uses `data.csv` in the repo root:

```bash
uv run python pull_info.py
```

### Custom CSV path

```bash
uv run python pull_info.py /path/to/holdings.csv
```

### Notes

- If the file does not exist, the script raises an error telling you to pass a path explicitly.
- If a row uses `CASH` as the ticker, the script prices it at `1.0` instead of calling Yahoo Finance.
- Fractional shares are supported.
- The file is updated in place.

## `agent.py`

`agent.py` uses Microsoft Agent Framework plus a Foundry-hosted model. It authenticates with a service principal stored in `.env`.
Every time it runs, it first refreshes the target CSV by calling `pull_info.py` logic.

### Required `.env` fields

These fields are used by the current script:

```env
DEFAULT_MODEL="gpt"
FOUNDRY_BASE_URL="https://<resource>.services.ai.azure.com/models"
AZURE_TENANT_ID="..."
AZURE_CLIENT_ID="..."
AZURE_CLIENT_SECRET="..."
GPT_MODEL="gpt-5.4"
GROK_MODEL="grok-4-1-fast-reasoning"
```

### Run a normal prompt

Use the default model from `.env`:

```bash
uv run python agent.py "Summarize this portfolio."
```

Force GPT:

```bash
uv run python agent.py --model gpt "Summarize this portfolio."
```

Force Grok:

```bash
uv run python agent.py --model grok "Summarize this portfolio."
```

Override the system prompt:

```bash
uv run python agent.py --model grok --system "You are a strict financial classifier." "Classify MSFT."
```

Use a non-default CSV for the refresh step:

```bash
uv run python agent.py --source /path/to/holdings.csv "Summarize this portfolio."
```

## CSV Classification With `agent.py`

`agent.py` can also classify each holding in the CSV and append a `classification` column.

### Default CSV

```bash
uv run python agent.py --model grok --classify-csv
```

This defaults to `data.csv`.

### Custom CSV path

```bash
uv run python agent.py --model grok --classify-csv /path/to/holdings.csv
```

### Classification behavior

- The script loops through each CSV row.
- Before classification starts, the script refreshes prices in the same CSV via `pull_info.py`.
- It reuses the same classification for repeated tickers.
- If the `classification` column already exists, it is overwritten.
- Common symbols in the current portfolio are classified locally without calling the model.
- Unknown symbols fall back to the selected Foundry model.

Examples of current categories include:

- `MSFT` -> `tech`
- `IBM` -> `tech`
- `AMD` -> `semiconductors`
- `NVDA` -> `semiconductors`
- `BTC-USD` -> `crypto`
- `CASH` -> `cash`

## Typical Workflow

Update prices first:

```bash
uv run python pull_info.py
```

Then classify holdings:

```bash
uv run python agent.py --model grok --classify-csv data.csv
```
