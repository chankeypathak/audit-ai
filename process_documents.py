import os
from llama_index.core import SimpleDirectoryReader, VectorStoreIndex, StorageContext
from llama_index.vector_stores.chroma import ChromaVectorStore
import chromadb
from langchain_community.embeddings import HuggingFaceBgeEmbeddings

def process_reports():
    # Load documents
    documents = SimpleDirectoryReader(
        input_dir="/opt/audit-ai/data/raw",
        recursive=True,
        required_exts=[".txt", ".html", ".pdf"]
    ).load_data()
    
    print("Init")
    # Initialize ChromaDB
    chroma_client = chromadb.PersistentClient(path="/opt/audit-ai/models/chroma_db")
    chroma_collection = chroma_client.create_collection("audit_reports")
    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    
    print("Embed")
    # Create embeddings
    embed_model = HuggingFaceBgeEmbeddings(
        model_name="BAAI/bge-small-en",
        model_kwargs={"device": "cpu"},
        encode_kwargs={"normalize_embeddings": True}
    )
    
    print("Vector Index")
    # Build vector index
    index = VectorStoreIndex.from_documents(
        documents,
        storage_context=storage_context,
        embed_model=embed_model
    )
    
    print("Store")
    # Save index
    index.storage_context.persist(persist_dir="/opt/audit-ai/models")
    return index

if __name__ == "__main__":
    process_reports()
