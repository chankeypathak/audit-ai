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
chroma_client = chromadb.PersistentClient(path="/opt/audit-ai/models/chroma_db")
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
    uvicorn.run(app, host="0.0.0.0", port=8000)
