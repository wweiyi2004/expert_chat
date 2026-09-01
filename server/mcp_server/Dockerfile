FROM python:3.12-slim
WORKDIR /app
COPY mcp_server/requirements.txt ./requirements.txt
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir --index-url "$PIP_INDEX_URL" -r requirements.txt
COPY mcp_server ./mcp_server
COPY gateway ./gateway
COPY doc_edit ./doc_edit
ENV MCP_DATA_DIR=/data
EXPOSE 8790
VOLUME ["/data"]
CMD ["uvicorn", "mcp_server.app.main:app", "--host", "0.0.0.0", "--port", "8790", "--workers", "1"]

