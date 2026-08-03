# Document Edit Service (P0)

Linux-side helper for Expert Chat: apply a `DocumentPatch` to `.xlsx` / `.docx` / `.pptx` and return the file.

Contract: [`docs/document-edit-contract.md`](../../docs/document-edit-contract.md)

## Run

```bash
cd server/doc_edit
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt

export DOC_API_TOKEN='change-me'
uvicorn app.main:app --host 0.0.0.0 --port 8787
```

## Smoke

```bash
curl -s http://127.0.0.1:8787/v1/health

curl -s -X POST http://127.0.0.1:8787/v1/documents/edit \
  -H "Authorization: Bearer change-me" \
  -F "file=@/path/to/in.xlsx" \
  -F 'patch={"schema_version":1,"format":"xlsx","ops":[{"op":"set_cells","cells":{"A1":"hi"}}]}' \
  -o out.xlsx
```

## Docker (optional)

```bash
docker build -t expert-chat-doc-edit .
docker run --rm -e DOC_API_TOKEN=change-me -p 8787:8787 expert-chat-doc-edit
```
