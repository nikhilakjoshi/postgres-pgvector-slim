"""
FastAPI Drop-in Query Cache Manager

A minimal, production-ready caching module that integrates seamlessly into
your existing FastAPI RAG pipeline.

Usage:
    from cache_manager import QueryCacheManager

    cache = QueryCacheManager(database_url="postgresql://...")

    # In your existing query flow:
    cached_result = await cache.check_cache(rephrased_query_embedding)
    if cached_result:
        return cached_result['answer']

    # After LLM processing:
    await cache.add_to_cache(user_msg_id, assistant_msg_id, rephrased_query, embedding)
"""

import asyncio
import logging
from typing import Optional, Dict, Any, List
from dataclasses import dataclass
from contextlib import asynccontextmanager

import asyncpg
import numpy as np
from pydantic import BaseModel, ConfigDict

logger = logging.getLogger(__name__)


@dataclass
class CacheHit:
    """Represents a cache hit result."""

    cache_id: str
    user_message_id: str
    assistant_message_id: str
    rephrased_query: str
    similarity_score: float
    cache_hits: int
    user_question: str
    assistant_answer: str
    user_parts: dict
    assistant_parts: dict
    user_annotations: dict
    assistant_annotations: dict


class CacheConfig(BaseModel):
    """Cache configuration settings."""

    model_config = ConfigDict(frozen=True)

    similarity_threshold: float = 0.85
    cache_enabled: bool = True
    max_cache_entries: int = 5000


class QueryCacheManager:
    """
    Drop-in cache manager for FastAPI applications.

    Provides semantic similarity-based caching for Q&A pairs to reduce LLM calls.
    """

    def __init__(self, database_url: str, pool_size: int = 10):
        """
        Initialize the cache manager.

        Args:
            database_url: PostgreSQL connection string
            pool_size: Connection pool size
        """
        self.database_url = database_url
        self.pool_size = pool_size
        self._pool: Optional[asyncpg.Pool] = None
        self._config: Optional[CacheConfig] = None

    async def initialize(self) -> None:
        """Initialize the connection pool and load configuration."""
        if self._pool is None:
            self._pool = await asyncpg.create_pool(
                self.database_url,
                min_size=1,
                max_size=self.pool_size,
                command_timeout=60,
            )
            await self._load_config()
            logger.info("Cache manager initialized")

    async def close(self) -> None:
        """Close the connection pool."""
        if self._pool:
            await self._pool.close()
            self._pool = None
            logger.info("Cache manager closed")

    @asynccontextmanager
    async def get_connection(self):
        """Get a database connection from the pool."""
        if not self._pool:
            await self.initialize()

        async with self._pool.acquire() as conn:
            yield conn

    async def _load_config(self) -> None:
        """Load configuration from the database."""
        try:
            async with self.get_connection() as conn:
                rows = await conn.fetch(
                    """
                    SELECT key, value FROM askwealth.query_cache_config
                """
                )

                config_dict = {row["key"]: row["value"] for row in rows}

                self._config = CacheConfig(
                    similarity_threshold=float(
                        config_dict.get("similarity_threshold", 0.85)
                    ),
                    cache_enabled=config_dict.get("cache_enabled", "true").lower()
                    == "true",
                    max_cache_entries=int(config_dict.get("max_cache_entries", 5000)),
                )

                logger.info(f"Loaded cache config: {self._config}")
        except Exception as e:
            logger.warning(f"Failed to load cache config, using defaults: {e}")
            self._config = CacheConfig()

    async def check_cache(
        self,
        rephrased_query_embedding: List[float],
        similarity_threshold: Optional[float] = None,
    ) -> Optional[CacheHit]:
        """
        Check if a similar query exists in cache.

        Args:
            rephrased_query_embedding: Vector embedding of the rephrased query
            similarity_threshold: Override default similarity threshold

        Returns:
            CacheHit object if found, None otherwise
        """
        if not self._config or not self._config.cache_enabled:
            return None

        threshold = similarity_threshold or self._config.similarity_threshold

        try:
            async with self.get_connection() as conn:
                # Find similar cached query
                cache_row = await conn.fetchrow(
                    """
                    SELECT cache_id, user_message_id, assistant_message_id, 
                           rephrased_query, similarity_score, cache_hits
                    FROM askwealth.find_similar_cached_query($1::vector, $2)
                """,
                    rephrased_query_embedding,
                    threshold,
                )

                if not cache_row:
                    return None

                # Get full answer details
                answer_row = await conn.fetchrow(
                    """
                    SELECT user_question, assistant_answer, user_parts, 
                           assistant_parts, user_annotations, assistant_annotations
                    FROM askwealth.get_cached_answer_details($1::uuid)
                """,
                    cache_row["cache_id"],
                )

                if not answer_row:
                    return None

                # Record the cache hit
                await conn.execute(
                    """
                    SELECT askwealth.record_cache_hit($1::uuid)
                """,
                    cache_row["cache_id"],
                )

                logger.info(
                    f"Cache hit: {cache_row['cache_id']} (similarity: {cache_row['similarity_score']:.3f})"
                )

                return CacheHit(
                    cache_id=str(cache_row["cache_id"]),
                    user_message_id=str(cache_row["user_message_id"]),
                    assistant_message_id=str(cache_row["assistant_message_id"]),
                    rephrased_query=cache_row["rephrased_query"],
                    similarity_score=float(cache_row["similarity_score"]),
                    cache_hits=cache_row["cache_hits"],
                    user_question=answer_row["user_question"],
                    assistant_answer=answer_row["assistant_answer"],
                    user_parts=answer_row["user_parts"],
                    assistant_parts=answer_row["assistant_parts"],
                    user_annotations=answer_row["user_annotations"],
                    assistant_annotations=answer_row["assistant_annotations"],
                )

        except Exception as e:
            logger.error(f"Error checking cache: {e}")
            return None

    async def add_to_cache(
        self,
        user_message_id: str,
        assistant_message_id: str,
        rephrased_query: str,
        rephrased_query_embedding: List[float],
    ) -> Optional[str]:
        """
        Add a new Q&A pair to the cache.

        Args:
            user_message_id: User message UUID
            assistant_message_id: Assistant message UUID
            rephrased_query: The rephrased query text
            rephrased_query_embedding: Vector embedding of the rephrased query

        Returns:
            Cache entry ID if successful, None otherwise
        """
        if not self._config or not self._config.cache_enabled:
            return None

        try:
            async with self.get_connection() as conn:
                cache_id = await conn.fetchval(
                    """
                    SELECT askwealth.add_cache_entry($1::uuid, $2::uuid, $3, $4::vector)
                """,
                    user_message_id,
                    assistant_message_id,
                    rephrased_query,
                    rephrased_query_embedding,
                )

                logger.info(f"Added to cache: {cache_id}")
                return str(cache_id) if cache_id else None

        except Exception as e:
            logger.error(f"Error adding to cache: {e}")
            return None

    async def get_cache_stats(self) -> Dict[str, Any]:
        """Get cache statistics for monitoring."""
        try:
            async with self.get_connection() as conn:
                stats = await conn.fetchrow(
                    """
                    SELECT 
                        COUNT(*) as total_entries,
                        COUNT(CASE WHEN rephrased_query_embedding IS NOT NULL THEN 1 END) as entries_with_embeddings,
                        COUNT(CASE WHEN cache_hits > 0 THEN 1 END) as entries_with_hits,
                        COALESCE(SUM(cache_hits), 0) as total_cache_hits,
                        COALESCE(AVG(cache_hits), 0) as avg_hits_per_entry,
                        COUNT(CASE WHEN created_at >= CURRENT_DATE - INTERVAL '7 days' THEN 1 END) as entries_last_7_days
                    FROM askwealth.query_cache_embeddings
                """
                )

                return dict(stats) if stats else {}

        except Exception as e:
            logger.error(f"Error getting cache stats: {e}")
            return {}

    async def update_config(self, **kwargs) -> bool:
        """Update cache configuration."""
        try:
            async with self.get_connection() as conn:
                for key, value in kwargs.items():
                    if hasattr(CacheConfig, key):
                        await conn.execute(
                            """
                            INSERT INTO askwealth.query_cache_config (key, value, updated_at)
                            VALUES ($1, $2, CURRENT_TIMESTAMP)
                            ON CONFLICT (key) DO UPDATE SET
                                value = EXCLUDED.value,
                                updated_at = EXCLUDED.updated_at
                        """,
                            key,
                            str(value),
                        )

                # Reload configuration
                await self._load_config()
                logger.info(f"Updated cache config: {kwargs}")
                return True

        except Exception as e:
            logger.error(f"Error updating cache config: {e}")
            return False

    async def cleanup_cache(self) -> int:
        """Clean up cache based on size limits."""
        try:
            async with self.get_connection() as conn:
                deleted_count = await conn.fetchval(
                    """
                    SELECT askwealth.cleanup_cache()
                """
                )

                if deleted_count > 0:
                    logger.info(f"Cleaned up {deleted_count} cache entries")

                return deleted_count or 0

        except Exception as e:
            logger.error(f"Error cleaning up cache: {e}")
            return 0

    async def populate_from_existing(self) -> int:
        """Populate cache from existing Q&A pairs (without embeddings)."""
        try:
            async with self.get_connection() as conn:
                populated_count = await conn.fetchval(
                    """
                    SELECT askwealth.populate_cache_from_existing()
                """
                )

                logger.info(
                    f"Populated {populated_count} entries from existing Q&A pairs"
                )
                return populated_count or 0

        except Exception as e:
            logger.error(f"Error populating cache: {e}")
            return 0


# Singleton instance for FastAPI dependency injection
_cache_manager: Optional[QueryCacheManager] = None


def get_cache_manager(database_url: str = None) -> QueryCacheManager:
    """Get or create the global cache manager instance."""
    global _cache_manager

    if _cache_manager is None and database_url:
        _cache_manager = QueryCacheManager(database_url)

    return _cache_manager


async def initialize_cache(database_url: str) -> QueryCacheManager:
    """Initialize the global cache manager."""
    global _cache_manager

    _cache_manager = QueryCacheManager(database_url)
    await _cache_manager.initialize()
    return _cache_manager


async def close_cache():
    """Close the global cache manager."""
    global _cache_manager

    if _cache_manager:
        await _cache_manager.close()
        _cache_manager = None


# FastAPI integration example
class CachedResponse(BaseModel):
    """Response model for cached answers."""

    answer: str
    source: str  # "cache" or "llm"
    cache_id: Optional[str] = None
    similarity_score: Optional[float] = None
    processing_time_ms: Optional[float] = None
    cache_hits: Optional[int] = None


async def process_query_with_cache(
    user_question: str,
    rephrased_query: str,
    rephrased_query_embedding: List[float],
    user_message_id: str,
    cache_manager: QueryCacheManager,
    llm_processor_func,  # Your existing LLM processing function
) -> CachedResponse:
    """
    Drop-in function to process queries with caching.

    This is the main integration point for your existing FastAPI application.
    """
    import time

    start_time = time.time()

    # Check cache first
    cache_hit = await cache_manager.check_cache(rephrased_query_embedding)

    if cache_hit:
        processing_time = (time.time() - start_time) * 1000
        return CachedResponse(
            answer=cache_hit.assistant_answer,
            source="cache",
            cache_id=cache_hit.cache_id,
            similarity_score=cache_hit.similarity_score,
            processing_time_ms=processing_time,
            cache_hits=cache_hit.cache_hits + 1,  # +1 for this hit
        )

    # Cache miss - proceed with LLM
    llm_result = await llm_processor_func(
        user_question, rephrased_query, rephrased_query_embedding
    )

    # Add to cache
    cache_id = await cache_manager.add_to_cache(
        user_message_id=user_message_id,
        assistant_message_id=llm_result.get("assistant_message_id"),
        rephrased_query=rephrased_query,
        rephrased_query_embedding=rephrased_query_embedding,
    )

    processing_time = (time.time() - start_time) * 1000

    return CachedResponse(
        answer=llm_result["answer"],
        source="llm",
        cache_id=cache_id,
        processing_time_ms=processing_time,
    )
