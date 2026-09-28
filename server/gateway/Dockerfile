FROM python:3.12-slim
WORKDIR /app
COPY requirements.lock ./requirements.lock
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir --index-url "$PIP_INDEX_URL" --require-hashes -r requirements.lock
COPY gateway ./gateway
COPY doc_edit ./doc_edit
COPY document_core ./document_core
ENV GATEWAY_DATA_DIR=/data
EXPOSE 8790
VOLUME ["/data"]
CMD ["uvicorn", "gateway.app.main:app", "--host", "0.0.0.0", "--port", "8790", "--workers", "1"]
