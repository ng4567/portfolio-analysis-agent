FROM python:3.14-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV UV_PROJECT_ENVIRONMENT=/opt/venv

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

COPY pull_info.py agent.py ./
COPY .env.template ./

ENV PATH="/opt/venv/bin:${PATH}"

CMD ["python", "agent.py", "--help"]

