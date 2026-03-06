import argparse
import asyncio
import csv
import os
from pathlib import Path

from agent_framework import ChatAgent
from agent_framework.openai import OpenAIChatClient
from azure.identity import ClientSecretCredential
from dotenv import load_dotenv
from openai import AsyncOpenAI
from pull_info import pull_info


MODEL_ENV_MAP = {
    "gpt": {
        "model_id": "GPT_MODEL",
    },
    "grok": {
        "model_id": "GROK_MODEL",
    },
}

CLASSIFICATION_COLUMN = "classification"
CSV_REQUIRED_COLUMNS = ["ticker", "num_shares", "broker", "type", "value"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a basic Microsoft Agent Framework agent against GPT or Grok."
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        default="Give me a one-sentence summary of this project.",
        help="Prompt to send to the agent.",
    )
    parser.add_argument(
        "--system",
        default="You are a helpful assistant.",
        help="System instructions for the agent.",
    )
    parser.add_argument(
        "--model",
        choices=sorted(MODEL_ENV_MAP),
        default=os.getenv("DEFAULT_MODEL", "gpt"),
        help="Which configured deployment to use.",
    )
    parser.add_argument(
        "--classify-csv",
        nargs="?",
        const="data.csv",
        help="Classify each holding in the CSV and write a trailing classification column.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("data.csv"),
        help="CSV file to refresh with pull_info before the agent runs. Defaults to data.csv.",
    )
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.getenv(name)
    if value:
        return value
    raise ValueError(
        f"Missing required environment variable: {name}. "
        "Populate it in .env before running this script."
    )


def build_chat_client(model_name: str) -> tuple[OpenAIChatClient, AsyncOpenAI, ClientSecretCredential]:
    model_config = MODEL_ENV_MAP[model_name]
    credential = ClientSecretCredential(
        tenant_id=require_env("AZURE_TENANT_ID"),
        client_id=require_env("AZURE_CLIENT_ID"),
        client_secret=require_env("AZURE_CLIENT_SECRET"),
    )
    token = credential.get_token("https://cognitiveservices.azure.com/.default")
    async_client = AsyncOpenAI(
        api_key=token.token,
        base_url=require_env("FOUNDRY_BASE_URL"),
    )
    chat_client = OpenAIChatClient(
        async_client=async_client,
        model_id=require_env(model_config["model_id"]),
    )
    return chat_client, async_client, credential


def normalize_classification(raw_text: str) -> str:
    text = raw_text.strip().lower()
    for marker in ("assistant:", "classification:", "category:"):
        if text.startswith(marker):
            text = text.removeprefix(marker).strip()
    return text.splitlines()[0].strip(" .\"'")


def is_rate_limit_error(exc: Exception) -> bool:
    message = str(exc).lower()
    return "429" in message or "rate limit" in message or "too many requests" in message


def get_fallback_model(model_name: str) -> str | None:
    fallback_models = [model for model in MODEL_ENV_MAP if model != model_name]
    return fallback_models[0] if fallback_models else None


def build_portfolio_context(source: str) -> str:
    with open(source, "r", newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        rows = list(reader)

    if not rows:
        return "Portfolio CSV is empty."

    lines = ["Portfolio CSV data:"]
    for row in rows:
        lines.append(
            ", ".join(
                [
                    f"ticker={row.get('ticker', '')}",
                    f"num_shares={row.get('num_shares', '')}",
                    f"broker={row.get('broker', '')}",
                    f"type={row.get('type', '')}",
                    f"value={row.get('value', '')}",
                    f"classification={row.get('classification', '')}",
                ]
            )
        )
    return "\n".join(lines)


async def run_agent(prompt: str, system_prompt: str, model_name: str) -> str:
    env_path = Path(__file__).with_name(".env")
    load_dotenv(env_path, override=True)

    chat_client, async_client, credential = build_chat_client(model_name)
    try:
        agent = ChatAgent(
            name=f"{model_name.title()}Agent",
            instructions=system_prompt,
            chat_client=chat_client,
        )
        response = await agent.run(prompt)
        return str(response)
    finally:
        await async_client.close()
        credential.close()


async def classify_ticker(ticker: str, model_name: str) -> str:
    system_prompt = (
        "Classify financial holdings into a short lowercase category. "
        "Return only the category label, no explanation. "
        "Prefer categories like tech, semiconductors, crypto, cash, healthcare, "
        "financials, consumer, communications, real_estate, tobacco, industrials, "
        "broad_market_etf, growth_fund, gambling, internet, china_tech."
    )
    user_prompt = (
        f"Ticker: {ticker}\n"
        "Examples:\n"
        "MSFT -> tech\n"
        "IBM -> tech\n"
        "AMD -> semiconductors\n"
        "NVDA -> semiconductors\n"
        "BTC-USD -> crypto\n"
        "CASH -> cash\n"
        "Respond with one category only."
    )
    return normalize_classification(await run_agent(user_prompt, system_prompt, model_name))


async def classify_csv(source: str, model_name: str) -> None:
    with open(source, "r", newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        if reader.fieldnames is None:
            raise ValueError("CSV file is empty.")

        missing_columns = [column for column in CSV_REQUIRED_COLUMNS if column not in reader.fieldnames]
        if missing_columns:
            raise ValueError(
                "CSV is missing required columns: " + ", ".join(missing_columns)
            )

        rows = list(reader)

    ticker_cache: dict[str, str] = {}
    active_model = model_name
    switched_model = False
    try:
        for row in rows:
            ticker = row["ticker"]
            if ticker not in ticker_cache:
                while True:
                    try:
                        ticker_cache[ticker] = await classify_ticker(ticker, active_model)
                        break
                    except Exception as exc:
                        if is_rate_limit_error(exc) and not switched_model:
                            fallback_model = get_fallback_model(active_model)
                            if fallback_model:
                                active_model = fallback_model
                                switched_model = True
                                continue
                        raise RuntimeError(
                            f"No model could classify '{ticker}'. Last error: {exc}"
                        ) from exc
            row[CLASSIFICATION_COLUMN] = ticker_cache[ticker]
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from exc

    output_columns = [column for column in reader.fieldnames if column != CLASSIFICATION_COLUMN]
    output_columns.append(CLASSIFICATION_COLUMN)

    with open(source, "w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=output_columns)
        writer.writeheader()
        writer.writerows(rows)

    for ticker, classification in sorted(ticker_cache.items()):
        print(f"{ticker}: {classification}")


def main() -> None:
    args = parse_args()
    source_path = args.source
    if args.classify_csv:
        source_path = Path(args.classify_csv)

    if not source_path.exists():
        raise FileNotFoundError(
            f"Could not find CSV file at '{source_path}'. "
            "Supply a path with --source or --classify-csv."
        )

    pull_info(str(source_path))

    if args.classify_csv:
        asyncio.run(classify_csv(str(source_path), args.model))
        return
    portfolio_context = build_portfolio_context(str(source_path))
    full_prompt = f"{portfolio_context}\n\nUser request: {args.prompt}"
    print(asyncio.run(run_agent(full_prompt, args.system, args.model)))


if __name__ == "__main__":
    main()
