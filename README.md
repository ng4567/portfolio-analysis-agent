# Portfolio Analysis Agent

## Intro

This project helps you visualize portfolio allocation using an LLM agent built with the Microsoft Agent Framework. It will create pie chart visualizations in [`analysis.ipynb`](./analysis.ipynb) of allocation in various sectors of all portfolios combined as well as by account type (taxable brokerage, ROTH IRA, 401k).

There is a template mock data file [`data.csv`](./data.csv). You may feel free to replace it with your actual portfolios to get personalized insights.

The workflow is:

1. Refresh holdings with current market values.
2. Classify each holding into a category (for example `tech`, `crypto`, `cash`, `semiconductors`).
3. Ask the agent to summarize your portfolio using the refreshed data.
4. Visualize the results in a Jupyter Notebook

## Scripts

- [`pull_info.py`](./pull_info.py)
  - Updates a holdings CSV with fresh `value` data from Yahoo Finance.
  - Supports `CASH` rows with fixed price `1.0`.
  - Prints broker/account totals and total portfolio value.
- [`agent.py`](./agent.py)
  - Calls `pull_info` first on every run.
  - Runs an LLM written in Microsoft Agent Framework against deployed Foundry models (`gpt` or `grok`).
  - Can classify holdings and append/overwrite a `classification` column.
  - Automatically fails over to the other model on rate-limit errors.

## Architecture

- Data source: CSV holdings file (example: [`data.csv`](./data.csv)).
- Price refresh: Yahoo Finance via [`pull_info.py`](./pull_info.py).
- LLM orchestration: Microsoft Agent Framework via [`agent.py`](./agent.py).
- Model endpoint: Azure AI Foundry model inference API.
- Auth: service principal credentials from [`.env`](./.env) (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`).

Runtime flow:

1. `agent.py` loads `.env`.
2. `agent.py` refreshes the target CSV via `pull_info`.
3. If `--classify-csv` is used, the script classifies holdings with the LLM and updates the CSV.
4. Otherwise, the script sends portfolio context + your prompt to the agent and returns a response.

## Dependencies

### Local runtime dependencies

- Python `3.14+`
- `uv` for local dependency management
- Docker + Docker Compose (only if running containerized)
- Azure CLI (`az`) for provisioning checks and deployment inspection
- Authenticated Azure session (`az login`) for dependency checks

### Azure dependencies that must be provisioned

- Azure subscription (`AZURE_SUBSCRIPTION_ID`)
- Azure AI Foundry account (`Microsoft.CognitiveServices/accounts`)
- Foundry model deployments:
  - `gpt-5.4`
  - `grok-4-1-fast-reasoning`
- Service principal with access to Foundry:
  - `AZURE_TENANT_ID`
  - `AZURE_CLIENT_ID`
  - `AZURE_CLIENT_SECRET`

### Dependency checker (Bicep)

This repo includes:

- Bicep template: [`infra/dependency-check.bicep`](./infra/dependency-check.bicep)
- Wrapper script: [`scripts/check-dependencies.sh`](./scripts/check-dependencies.sh)

The wrapper reads `.env` (including `AZURE_SUBSCRIPTION_ID`) and runs a subscription-scope deployment that reports missing dependencies and recommended provisioning actions.
By default, the wrapper uses a fast local Azure CLI check. To force the ARM/Bicep deployment path, set `USE_BICEP_CHECK=true`.

## Setup

### Containerized

Build once:

```bash
docker compose build
```

Compose config is in [`docker-compose.yml`](./docker-compose.yml), image build is in [`Dockerfile`](./Dockerfile), and `.env` is mounted into `/app`.

### Local

```bash
uv sync
```

Create [`.env`](./.env) from [`.env.template`](./.env.template), then edit `.env` with your real values:

```env
DEFAULT_MODEL="gpt"
FOUNDRY_BASE_URL="https://<resource>.services.ai.azure.com/models"
AZURE_SUBSCRIPTION_ID="..."
AZURE_LOCATION="eastus"
RESOURCE_GROUP_NAME="..."
FOUNDRY_ACCOUNT_NAME="..."
AZURE_TENANT_ID="..."
AZURE_CLIENT_ID="..."
AZURE_CLIENT_SECRET="..."
GPT_MODEL="gpt-5.4"
GROK_MODEL="grok-4-1-fast-reasoning"
```

## CSV Format

Input schema:

```csv
ticker,num_shares,broker,type
```

After `pull_info.py`:

```csv
ticker,num_shares,broker,type,value
```

After `agent.py --classify-csv`:

```csv
ticker,num_shares,broker,type,value,classification
```

[`data.csv`](./data.csv) in this repo is mock data for safe sharing. Keep personal holdings in a local ignored file (for example [`nikhil-data.csv`](./nikhil-data.csv)).

## Usage

### Refresh prices

```bash
uv run python pull_info.py data.csv
```

Container:

```bash
docker compose run --rm app python pull_info.py
```

### Check if Cloud Dependencies are Provisioned

```bash
bash scripts/check-dependencies.sh
```

Force ARM/Bicep path:

```bash
USE_BICEP_CHECK=true bash scripts/check-dependencies.sh
```

### Ask the agent for a summary

```bash
uv run python agent.py --source data.csv "Summarize my portfolio" --model grok
uv run python agent.py --source nikhil-data.csv "Summarize my portfolio" --model gpt
```

Container:

```bash
docker compose run --rm app python agent.py --source data.csv "Summarize my portfolio" --model grok
```

### Classify holdings

```bash
uv run python agent.py --classify-csv data.csv --model grok
uv run python agent.py --classify-csv nikhil-data.csv --model gpt
```

Container:

```bash
docker compose run --rm app python agent.py --classify-csv data.csv --model grok
```
