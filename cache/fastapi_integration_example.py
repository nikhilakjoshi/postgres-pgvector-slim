"""
FastAPI Integration Example

This file shows how to integrate the query cache into your existing FastAPI application.
"""

from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel
from typing import List, Optional, Dict, Any
import os
import logging
from contextlib import asynccontextmanager

# Import the cache manager
from cache_manager import (
    QueryCacheManager,
    CachedResponse,
    initialize_cache,
    close_cache,
    get_cache_manager,
)

logger = logging.getLogger(__name__)


# Pydantic models for your API
class QueryRequest(BaseModel):
    question: str
    thread_id: Optional[str] = None


class QueryResponse(BaseModel):
    answer: str
    source: str  # "cache" or "llm"
    cache_id: Optional[str] = None
    similarity_score: Optional[float] = None
    processing_time_ms: float
    metadata: Optional[Dict[str, Any]] = None


# FastAPI lifespan for cache initialization
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize and cleanup cache on app startup/shutdown."""

    # Startup
    database_url = os.getenv(
        "DATABASE_URL",
        "postgresql://askwealth_rw_dev:hello@localhost:5432/askwealth-dev",
    )
    cache_manager = await initialize_cache(database_url)

    logger.info("Cache manager initialized")

    yield

    # Shutdown
    await close_cache()
    logger.info("Cache manager closed")


# Create FastAPI app with lifespan
app = FastAPI(
    title="AskWealth API with Caching",
    description="FastAPI application with intelligent query caching",
    lifespan=lifespan,
)


# Dependency to get cache manager
async def get_cache_dep() -> QueryCacheManager:
    """Dependency to get the cache manager."""
    cache_manager = get_cache_manager()
    if not cache_manager:
        raise HTTPException(status_code=500, detail="Cache manager not initialized")
    return cache_manager


# Your existing functions (mock implementations)
async def generate_rephrased_query(question: str) -> str:
    """Mock function - replace with your LLM call to rephrase the query."""
    # Your existing rephrasing logic here
    return f"rephrased: {question}"


async def generate_embedding(text: str) -> List[float]:
    """Mock function - replace with your embedding generation."""
    # Your existing embedding logic here
    return [0.1] * 1536  # Mock 1536-dimensional embedding


async def process_with_rag(
    original_question: str, rephrased_query: str, embedding: List[float]
) -> Dict[str, Any]:
    """Mock function - replace with your RAG processing."""
    # Your existing RAG logic here
    return {
        "answer": f"Mock answer for: {original_question}",
        "chunks_used": 3,
        "assistant_message_id": "mock-assistant-id",
    }


async def save_user_message(question: str, thread_id: str, rephrased_query: str) -> str:
    """Mock function - replace with your message saving logic."""
    # Your existing message saving logic here
    return "mock-user-message-id"


# Modified query endpoint with caching
@app.post("/query", response_model=QueryResponse)
async def process_query(
    request: QueryRequest, cache_manager: QueryCacheManager = Depends(get_cache_dep)
):
    """
    Process a user query with intelligent caching.

    This is your main query endpoint with the cache integration.
    """
    import time

    start_time = time.time()

    try:
        # Step 1: Generate rephrased query (existing logic)
        rephrased_query = await generate_rephrased_query(request.question)

        # Step 2: Generate embedding (existing logic)
        query_embedding = await generate_embedding(rephrased_query)

        # Step 3: Check cache (NEW)
        cache_hit = await cache_manager.check_cache(query_embedding)

        if cache_hit:
            # Cache hit - return cached answer
            processing_time = (time.time() - start_time) * 1000

            return QueryResponse(
                answer=cache_hit.assistant_answer,
                source="cache",
                cache_id=cache_hit.cache_id,
                similarity_score=cache_hit.similarity_score,
                processing_time_ms=processing_time,
                metadata={
                    "cache_hits": cache_hit.cache_hits + 1,
                    "original_cached_question": cache_hit.user_question,
                    "rephrased_query": cache_hit.rephrased_query,
                },
            )

        # Step 4: Cache miss - proceed with RAG (existing logic)
        rag_result = await process_with_rag(
            request.question, rephrased_query, query_embedding
        )

        # Step 5: Save messages (existing logic)
        user_message_id = await save_user_message(
            request.question, request.thread_id or "default-thread", rephrased_query
        )

        # Step 6: Add to cache (NEW)
        cache_id = await cache_manager.add_to_cache(
            user_message_id=user_message_id,
            assistant_message_id=rag_result["assistant_message_id"],
            rephrased_query=rephrased_query,
            rephrased_query_embedding=query_embedding,
        )

        processing_time = (time.time() - start_time) * 1000

        return QueryResponse(
            answer=rag_result["answer"],
            source="llm",
            cache_id=cache_id,
            processing_time_ms=processing_time,
            metadata={
                "chunks_used": rag_result.get("chunks_used", 0),
                "rephrased_query": rephrased_query,
            },
        )

    except Exception as e:
        logger.error(f"Query processing failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# Cache management endpoints
@app.get("/cache/stats")
async def get_cache_stats(cache_manager: QueryCacheManager = Depends(get_cache_dep)):
    """Get cache statistics."""
    stats = await cache_manager.get_cache_stats()
    return stats


@app.post("/cache/cleanup")
async def cleanup_cache(cache_manager: QueryCacheManager = Depends(get_cache_dep)):
    """Clean up cache based on size limits."""
    deleted_count = await cache_manager.cleanup_cache()
    return {"deleted_entries": deleted_count}


@app.post("/cache/populate")
async def populate_cache(cache_manager: QueryCacheManager = Depends(get_cache_dep)):
    """Populate cache from existing Q&A pairs."""
    populated_count = await cache_manager.populate_from_existing()
    return {"populated_entries": populated_count}


@app.put("/cache/config")
async def update_cache_config(
    similarity_threshold: Optional[float] = None,
    cache_enabled: Optional[bool] = None,
    max_cache_entries: Optional[int] = None,
    cache_manager: QueryCacheManager = Depends(get_cache_dep),
):
    """Update cache configuration."""
    config_updates = {}

    if similarity_threshold is not None:
        config_updates["similarity_threshold"] = similarity_threshold
    if cache_enabled is not None:
        config_updates["cache_enabled"] = cache_enabled
    if max_cache_entries is not None:
        config_updates["max_cache_entries"] = max_cache_entries

    if config_updates:
        success = await cache_manager.update_config(**config_updates)
        return {"success": success, "updated": config_updates}
    else:
        return {"success": False, "message": "No configuration updates provided"}


# Health check
@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "cache": "enabled"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
