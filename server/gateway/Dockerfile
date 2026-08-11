FROM python:3.12-slim
WORKDIR /app
COPY gateway/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY gateway ./gateway
COPY doc_edit ./doc_edit
ENV GATEWAY_DATA_DIR=/data
EXPOSE 8790
VOLUME ["/data"]
CMD ["uvicorn", "gateway.app.main:app", "--host", "0.0.0.0", "--port", "8790", "--workers", "1"]
