#!/bin/bash

# Enterprise Audit AI Analyzer - Clean Dependency Version
# Uses only stable, well-supported packages

# Configuration
APP_DIR="/opt/audit-ai"
DATA_DIR="$APP_DIR/data"
MODEL_DIR="$APP_DIR/models"
LOG_DIR="/var/log/audit-ai"
VENV_DIR="$APP_DIR/venv"
PORT=8000
SAMPLE_DOCS=50
YOUR_EMAIL="your.email@example.com"  # REPLACE WITH YOUR ACTUAL EMAIL

# Create directory structure
echo "[+] Creating directory structure"
sudo mkdir -p "$APP_DIR" "$DATA_DIR/raw" "$DATA_DIR/processed" "$MODEL_DIR" "$LOG_DIR"
sudo chown -R $(whoami) "$APP_DIR"
sudo chmod -R 755 "$LOG_DIR"

# Install system dependencies
echo "[+] Installing system dependencies"
sudo apt-get update && sudo apt-get install -y \
    python3 python3-venv python3-pip \
    git wget curl jq unzip \
    libssl-dev libffi-dev \
    nginx supervisor \
    poppler-utils tesseract-ocr \
    python3-dev

# Create Python virtual environment
echo "[+] Setting up Python environment"
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

# Install core dependencies first
echo "[+] Installing core Python dependencies"
pip install --upgrade pip setuptools==68.2.2 wheel==0.41.3
pip install requests==2.31.0 numpy==1.26.0

# Install main packages with stable versions
echo "[+] Installing main packages"

# Download sample SEC filings
echo "[+] Downloading $SAMPLE_DOCS sample SEC filings"
cd "$DATA_DIR/raw"
python3 -c "
import os
import csv
import requests
from sec_edgar_downloader import Downloader

# Get S&P 500 tickers
sp500_url = 'https://datahub.io/core/s-and-p-500-companies/r/constituents.csv'
response = requests.get(sp500_url)
reader = csv.DictReader(response.text.splitlines())
tickers = [row['Symbol'] for row in reader]

# Add additional tickers
additional_tickers = ['TSLA', 'SPOT', 'UBER', 'LYFT', 'SNAP', 'DASH', 'COIN', 'PLTR']
tickers = (tickers + additional_tickers)[:$SAMPLE_DOCS]

# Initialize Downloader with email and download directory
# dl = Downloader('$YOUR_EMAIL', '$DATA_DIR/raw')
# for ticker in tickers:
#     try:
#         dl.get('10-K', ticker, limit=1)
#         print(f'Downloaded 10-K for {ticker}')
#     except Exception as e:
#         print(f'Failed to download {ticker}: {str(e)}')
"

# Create document processing script
echo "[+] Creating document processing pipeline"
cat > "$APP_DIR/process_documents.py" <<EOL
import os
from llama_index.core import SimpleDirectoryReader, VectorStoreIndex, StorageContext
from llama_index.vector_stores.chroma import ChromaVectorStore
import chromadb
from sentence_transformers import SentenceTransformer

def process_reports():
    # Load documents
    documents = SimpleDirectoryReader(
        input_dir="$DATA_DIR/raw",
        recursive=True,
        required_exts=[".txt", ".html", ".pdf"]
    ).load_data()
    
    # Initialize ChromaDB
    chroma_client = chromadb.PersistentClient(path="$MODEL_DIR/chroma_db")
    try:
        chroma_collection = chroma_client.get_collection("audit_reports")
        print("Using existing collection")
    except:
        chroma_collection = chroma_client.create_collection("audit_reports")
        print("Created new collection")
    
    # Initialize embeddings
    embed_model = SentenceTransformer('all-MiniLM-L6-v2')
    
    # Custom embedding function
    def embed_function(texts):
        return embed_model.encode(texts).tolist()
    
    # Build vector index
    vector_store = ChromaVectorStore(
        chroma_collection=chroma_collection,
        embed_function=embed_function
    )
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    index = VectorStoreIndex.from_documents(
        documents,
        storage_context=storage_context
    )
    
    # Save index
    index.storage_context.persist(persist_dir="$MODEL_DIR")
    return index

if __name__ == "__main__":
    process_reports()
EOL

# Create FastAPI application
echo "[+] Creating FastAPI application"
cat > "$APP_DIR/main.py" <<EOL
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from llama_index.core import VectorStoreIndex, StorageContext
from llama_index.vector_stores.chroma import ChromaVectorStore
import chromadb
from pydantic import BaseModel
import uvicorn

app = FastAPI(title="Enterprise Audit AI Analyzer",
              description="AI-powered audit report comparison system",
              version="1.0.0")

# CORS configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize ChromaDB
chroma_client = chromadb.PersistentClient(path="$MODEL_DIR/chroma_db")
chroma_collection = chroma_client.get_collection("audit_reports")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(
    vector_store, storage_context=storage_context
)

class ComparisonRequest(BaseModel):
    document_text: str
    threshold: float = 0.8
    top_k: int = 5

class DiscrepancyItem(BaseModel):
    source: str
    target: str
    similarity: float
    discrepancy_type: str
    suggested_resolution: str

@app.post("/compare")
async def compare_audit_documents(request: ComparisonRequest):
    """Compare new audit document against existing corpus"""
    query_engine = index.as_query_engine(similarity_top_k=request.top_k)
    response = query_engine.query(
        f"Compare this audit document with existing reports and identify discrepancies: {request.document_text}"
    )
    
    # Process response
    discrepancies = []
    for node in response.source_nodes:
        if node.score >= request.threshold:
            discrepancies.append({
                "source": request.document_text[:200] + "...",
                "target": node.node.text[:200] + "...",
                "similarity": float(node.score),
                "discrepancy_type": "Content mismatch",
                "suggested_resolution": "Review both documents for regulatory compliance"
            })
    
    return {"discrepancies": discrepancies, "summary": str(response)}

@app.get("/reports")
async def list_available_reports():
    """List all processed audit reports"""
    return {"reports": chroma_collection.count()}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=$PORT)
EOL

# Create supervisor configuration
echo "[+] Creating supervisor service"
sudo bash -c "cat > /etc/supervisor/conf.d/audit-ai.conf" <<EOL
[program:audit-ai]
command=$VENV_DIR/bin/uvicorn main:app --host 0.0.0.0 --port $PORT
directory=$APP_DIR
user=$(whoami)
autostart=true
autorestart=true
stderr_logfile=$LOG_DIR/audit-ai.err.log
stdout_logfile=$LOG_DIR/audit-ai.out.log
environment=PYTHONPATH="$APP_DIR"
EOL

# Create Nginx configuration
echo "[+] Creating Nginx reverse proxy"
sudo bash -c "cat > /etc/nginx/sites-available/audit-ai" <<EOL
server {
    listen 80;
    server_name audit-ai.local;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    access_log $LOG_DIR/nginx-access.log;
    error_log $LOG_DIR/nginx-error.log;
}
EOL

# Enable services
echo "[+] Enabling services"
sudo ln -s /etc/nginx/sites-available/audit-ai /etc/nginx/sites-enabled/
sudo supervisorctl reread
sudo supervisorctl update
sudo systemctl restart nginx supervisor

# Process documents
echo "[+] Processing downloaded documents"
cd "$APP_DIR"
python process_documents.py

echo "[+] Deployment complete!"
echo "Access the API at: http://localhost:$PORT"
echo "Test with:"
echo "curl -X GET http://localhost:$PORT/reports"
echo "curl -X POST -H \"Content-Type: application/json\" -d '{\"document_text\":\"Sample audit finding...\", \"threshold\": 0.7}' http://localhost:$PORT/compare"