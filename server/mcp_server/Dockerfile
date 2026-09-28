FROM python:3.12-slim
WORKDIR /app
COPY requirements.lock ./requirements.lock
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir --index-url "$PIP_INDEX_URL" --require-hashes -r requirements.lock
COPY mcp_server ./mcp_server
COPY doc_edit ./doc_edit
COPY document_core ./document_core
RUN useradd --system --uid 10001 --create-home expert && mkdir -p /data && chown expert /data
ENV MCP_DATA_DIR=/data
USER expert
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8790/health', timeout=3)"
EXPOSE 8790
VOLUME ["/data"]
CMD ["uvicorn", "mcp_server.app.main:app", "--host", "0.0.0.0", "--port", "8790", "--workers", "1"]

