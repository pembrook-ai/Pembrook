FROM python:3.13-slim

# Install Docker CLI (needed for `docker compose logs -f`).
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -fsSL https://get.docker.com | sh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY server.py index.html ./

EXPOSE 9090
CMD ["python3", "server.py"]
