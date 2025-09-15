# Caching Module API Integration Guide

## Overview

This guide shows how to integrate the AskWealth caching module into your application to reduce LLM calls through intelligent question-answer caching.

## Quick Start

### 1. Database Setup

```bash
# The caching module is automatically initialized when you start the Docker container
docker-compose up -d

# Or manually run the initialization
docker-compose exec postgres psql -U askwealth_rw_dev -d askwealth-dev -f /docker-entrypoint-initdb.d/02-init-caching.sql
```

### 2. Basic Integration Pattern

```python
import psycopg2
import openai
from typing import Optional, Dict, Any

class CacheManager:
    def __init__(self, db_connection_string: str, openai_api_key: str):
        self.conn = psycopg2.connect(db_connection_string)
        openai.api_key = openai_api_key

    def find_cached_answer(self, question_embedding: list, threshold: float = None) -> Optional[Dict]:
        """Find a cached answer for the given question embedding."""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT cache_id, original_question, rephrased_question,
                       answer_text, answer_metadata, similarity_score, cache_hits
                FROM askwealth.find_cached_answer(%s::vector, %s)
            """, [question_embedding, threshold])

            result = cur.fetchone()
            if result:
                return {
                    'cache_id': result[0],
                    'original_question': result[1],
                    'rephrased_question': result[2],
                    'answer_text': result[3],
                    'answer_metadata': result[4],
                    'similarity_score': float(result[5]),
                    'cache_hits': result[6]
                }
        return None

    def record_cache_hit(self, cache_id: str) -> bool:
        """Record that a cached answer was used."""
        with self.conn.cursor() as cur:
            cur.execute("SELECT askwealth.record_cache_hit(%s::uuid)", [cache_id])
            return cur.fetchone()[0]

    def add_to_cache(self, thread_id: str, user_msg_id: str, assistant_msg_id: str,
                     original_question: str, rephrased_question: str,
                     question_embedding: list, answer_text: str,
                     answer_metadata: dict = None) -> str:
        """Add a new Q&A pair to the cache."""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT askwealth.add_to_cache(%s::uuid, %s::uuid, %s::uuid, %s, %s, %s::vector, %s, %s)
            """, [thread_id, user_msg_id, assistant_msg_id, original_question,
                  rephrased_question, question_embedding, answer_text, answer_metadata])
            return cur.fetchone()[0]

# Usage example
cache_manager = CacheManager(
    "postgresql://askwealth_rw_dev:hello@localhost:5432/askwealth-dev",
    "your-openai-api-key"
)
```

## Complete Integration Example

### Main Query Processing Function

```python
import openai
import json
from typing import Tuple

def process_user_question(user_question: str, thread_id: str, user_id: str) -> Dict[str, Any]:
    """
    Process a user question with caching support.

    Returns:
        Dictionary containing the answer and metadata about cache usage
    """

    # Step 1: Generate rephrased query
    rephrased_query = generate_rephrased_query(user_question)

    # Step 2: Generate embedding for the rephrased query
    question_embedding = generate_embedding(rephrased_query)

    # Step 3: Check cache for similar questions
    cached_result = cache_manager.find_cached_answer(question_embedding)

    if cached_result and cached_result['similarity_score'] >= 0.85:  # Configurable threshold
        # Cache hit - record usage and return cached answer
        cache_manager.record_cache_hit(cached_result['cache_id'])

        return {
            'answer': cached_result['answer_text'],
            'source': 'cache',
            'cache_id': cached_result['cache_id'],
            'similarity_score': cached_result['similarity_score'],
            'original_cached_question': cached_result['original_question'],
            'processing_time_ms': 50  # Much faster than LLM
        }

    # Cache miss - proceed with LLM call
    start_time = time.time()

    # Step 4: Retrieve relevant chunks (your existing RAG logic)
    relevant_chunks = retrieve_relevant_chunks(rephrased_query, question_embedding)

    # Step 5: Generate answer using LLM
    llm_answer = generate_llm_answer(user_question, relevant_chunks)

    processing_time = (time.time() - start_time) * 1000

    # Step 6: Store the new Q&A pair in cache
    user_msg_id = create_user_message(thread_id, user_question, user_id)
    assistant_msg_id = create_assistant_message(thread_id, llm_answer, 'assistant')

    cache_id = cache_manager.add_to_cache(
        thread_id=thread_id,
        user_msg_id=user_msg_id,
        assistant_msg_id=assistant_msg_id,
        original_question=user_question,
        rephrased_question=rephrased_query,
        question_embedding=question_embedding,
        answer_text=llm_answer,
        answer_metadata={
            'chunks_used': len(relevant_chunks),
            'llm_model': 'gpt-4',
            'processing_time_ms': processing_time
        }
    )

    return {
        'answer': llm_answer,
        'source': 'llm',
        'cache_id': cache_id,
        'chunks_used': len(relevant_chunks),
        'processing_time_ms': processing_time
    }

def generate_rephrased_query(user_question: str) -> str:
    """Generate a rephrased version of the user question for better matching."""
    response = openai.ChatCompletion.create(
        model="gpt-3.5-turbo",  # Use a smaller, faster model for rephrasing
        messages=[
            {
                "role": "system",
                "content": """Rephrase the user's question to create a normalized version suitable for semantic matching.
                Make it concise, clear, and focused on the core intent. Remove filler words and personal pronouns."""
            },
            {"role": "user", "content": user_question}
        ],
        max_tokens=100,
        temperature=0.1
    )
    return response.choices[0].message.content.strip()

def generate_embedding(text: str) -> list:
    """Generate embedding for the given text."""
    response = openai.Embedding.create(
        model="text-embedding-ada-002",
        input=text
    )
    return response.data[0].embedding
```

### Message Storage Integration

```python
def create_user_message(thread_id: str, question: str, user_id: str,
                       rephrased_query: str = None) -> str:
    """Create a user message with annotations for rephrased query."""

    message_parts = [{"text": question, "type": "text"}]
    annotations = {}

    if rephrased_query:
        annotations['rephrased_query'] = rephrased_query
        annotations['rephrasing'] = {'query': rephrased_query}

    with cache_manager.conn.cursor() as cur:
        cur.execute("""
            INSERT INTO askwealth.message (message_id, thread_id, role, parts, annotations, created_by)
            VALUES (gen_random_uuid(), %s::uuid, 'user', %s, %s, %s)
            RETURNING message_id
        """, [thread_id, json.dumps(message_parts), json.dumps(annotations), user_id])

        return cur.fetchone()[0]

def create_assistant_message(thread_id: str, answer: str, role: str = 'assistant') -> str:
    """Create an assistant message with the answer."""

    message_parts = [{"text": answer, "type": "text"}]

    with cache_manager.conn.cursor() as cur:
        cur.execute("""
            INSERT INTO askwealth.message (message_id, thread_id, role, parts, created_by)
            VALUES (gen_random_uuid(), %s::uuid, %s, %s, 'system')
            RETURNING message_id
        """, [thread_id, role, json.dumps(message_parts)])

        return cur.fetchone()[0]
```

## Configuration Management

### Dynamic Configuration Updates

```python
class CacheConfig:
    def __init__(self, db_connection):
        self.conn = db_connection

    def get_config(self, key: str) -> Any:
        """Get a configuration value."""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT config_value FROM askwealth.cache_config WHERE config_key = %s
            """, [key])
            result = cur.fetchone()
            return json.loads(result[0]) if result else None

    def set_config(self, key: str, value: Any, description: str = None):
        """Set a configuration value."""
        with self.conn.cursor() as cur:
            cur.execute("""
                INSERT INTO askwealth.cache_config (config_key, config_value, description)
                VALUES (%s, %s, %s)
                ON CONFLICT (config_key) DO UPDATE SET
                    config_value = EXCLUDED.config_value,
                    description = COALESCE(EXCLUDED.description, askwealth.cache_config.description),
                    updated_at = CURRENT_TIMESTAMP
            """, [key, json.dumps(value), description])

    def is_cache_enabled(self) -> bool:
        """Check if caching is globally enabled."""
        return self.get_config('enable_cache') is True

    def get_similarity_threshold(self) -> float:
        """Get the current similarity threshold."""
        return float(self.get_config('similarity_threshold') or 0.85)

# Usage
config = CacheConfig(cache_manager.conn)
if config.is_cache_enabled():
    threshold = config.get_similarity_threshold()
    # ... proceed with cache lookup
```

## Monitoring and Analytics

### Cache Performance Dashboard

```python
def get_cache_dashboard_data() -> Dict[str, Any]:
    """Get comprehensive cache performance data."""

    with cache_manager.conn.cursor() as cur:
        # Overall statistics
        cur.execute("SELECT * FROM askwealth.v_cache_stats")
        stats = dict(zip([desc[0] for desc in cur.description], cur.fetchone()))

        # Cache hit rate over time
        cur.execute("""
            SELECT
                DATE(created_at) as date,
                COUNT(*) as questions_cached,
                SUM(cache_hits) as total_hits
            FROM askwealth.qa_cache
            WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'
            GROUP BY DATE(created_at)
            ORDER BY date
        """)
        daily_stats = cur.fetchall()

        # Top performing cache entries
        cur.execute("""
            SELECT original_question, cache_hits, created_at
            FROM askwealth.qa_cache
            WHERE cache_hits > 0
            ORDER BY cache_hits DESC
            LIMIT 10
        """)
        top_entries = cur.fetchall()

        # Recent cache activity
        cur.execute("""
            SELECT original_question, answer_text, cache_hits, last_hit_at
            FROM askwealth.qa_cache
            WHERE last_hit_at >= CURRENT_DATE - INTERVAL '7 days'
            ORDER BY last_hit_at DESC
            LIMIT 20
        """)
        recent_activity = cur.fetchall()

        return {
            'stats': stats,
            'daily_performance': daily_stats,
            'top_entries': top_entries,
            'recent_activity': recent_activity
        }

def calculate_cost_savings(cache_hits: int, avg_llm_cost_per_query: float = 0.01) -> Dict[str, float]:
    """Calculate estimated cost savings from cache usage."""
    total_savings = cache_hits * avg_llm_cost_per_query

    return {
        'total_cache_hits': cache_hits,
        'estimated_cost_per_llm_query': avg_llm_cost_per_query,
        'total_estimated_savings': total_savings,
        'monthly_projected_savings': total_savings * 30  # If daily data
    }
```

## Maintenance Jobs

### Automated Cleanup

```python
import schedule
import time

def setup_maintenance_jobs():
    """Set up automated maintenance jobs."""

    # Daily cleanup
    schedule.every().day.at("02:00").do(daily_cache_maintenance)

    # Weekly analysis
    schedule.every().sunday.at("03:00").do(weekly_cache_analysis)

    # Monthly optimization
    schedule.every().month.do(monthly_cache_optimization)

def daily_cache_maintenance():
    """Daily cache maintenance tasks."""
    with cache_manager.conn.cursor() as cur:
        # Clean expired entries
        cur.execute("SELECT askwealth.cleanup_expired_cache()")
        expired_count = cur.fetchone()[0]

        # Enforce size limits
        cur.execute("SELECT askwealth.enforce_cache_size_limit()")
        removed_count = cur.fetchone()[0]

        print(f"Daily maintenance: Removed {expired_count} expired entries, {removed_count} size-limit entries")

def weekly_cache_analysis():
    """Weekly cache performance analysis."""
    dashboard_data = get_cache_dashboard_data()

    # Log performance metrics
    stats = dashboard_data['stats']
    print(f"Weekly analysis: {stats['total_entries']} total entries, {stats['total_cache_hits']} total hits")

    # Identify optimization opportunities
    hit_rate = stats['entries_with_hits'] / max(stats['total_entries'], 1) * 100
    if hit_rate < 20:
        print(f"Warning: Low cache hit rate ({hit_rate:.1f}%). Consider adjusting similarity threshold.")

def monthly_cache_optimization():
    """Monthly cache optimization and cleanup."""
    # Analyze and potentially adjust similarity threshold
    # Archive very old entries
    # Update vector index statistics
    pass

# Run maintenance scheduler
if __name__ == "__main__":
    setup_maintenance_jobs()
    while True:
        schedule.run_pending()
        time.sleep(60)
```

## Testing and Validation

### Unit Tests

```python
import unittest
from unittest.mock import Mock, patch

class TestCacheManager(unittest.TestCase):

    def setUp(self):
        self.cache_manager = CacheManager("test_connection_string", "test_api_key")
        self.cache_manager.conn = Mock()

    def test_find_cached_answer_hit(self):
        """Test cache hit scenario."""
        # Mock database response
        mock_cursor = Mock()
        mock_cursor.fetchone.return_value = [
            'cache-id', 'original question', 'rephrased question',
            'cached answer', '{}', 0.92, 5
        ]
        self.cache_manager.conn.cursor.return_value.__enter__.return_value = mock_cursor

        embedding = [0.1] * 1536
        result = self.cache_manager.find_cached_answer(embedding)

        self.assertIsNotNone(result)
        self.assertEqual(result['similarity_score'], 0.92)
        self.assertEqual(result['cache_hits'], 5)

    def test_find_cached_answer_miss(self):
        """Test cache miss scenario."""
        mock_cursor = Mock()
        mock_cursor.fetchone.return_value = None
        self.cache_manager.conn.cursor.return_value.__enter__.return_value = mock_cursor

        embedding = [0.1] * 1536
        result = self.cache_manager.find_cached_answer(embedding)

        self.assertIsNone(result)

    def test_record_cache_hit(self):
        """Test cache hit recording."""
        mock_cursor = Mock()
        mock_cursor.fetchone.return_value = [True]
        self.cache_manager.conn.cursor.return_value.__enter__.return_value = mock_cursor

        result = self.cache_manager.record_cache_hit('test-cache-id')

        self.assertTrue(result)

if __name__ == '__main__':
    unittest.main()
```

## Performance Tuning

### Embedding Generation Optimization

```python
import asyncio
import aiohttp
from concurrent.futures import ThreadPoolExecutor

class OptimizedEmbeddingGenerator:
    def __init__(self, api_key: str, max_workers: int = 5):
        self.api_key = api_key
        self.executor = ThreadPoolExecutor(max_workers=max_workers)

    async def generate_embeddings_batch(self, texts: list) -> list:
        """Generate embeddings for multiple texts in parallel."""

        async def generate_single(text):
            response = await openai.Embedding.acreate(
                model="text-embedding-ada-002",
                input=text
            )
            return response.data[0].embedding

        tasks = [generate_single(text) for text in texts]
        return await asyncio.gather(*tasks)

# Usage for batch processing
async def populate_missing_embeddings():
    """Populate embeddings for cache entries that don't have them."""

    with cache_manager.conn.cursor() as cur:
        cur.execute("""
            SELECT cache_id, rephrased_question
            FROM askwealth.qa_cache
            WHERE question_embedding IS NULL
            LIMIT 100
        """)

        entries = cur.fetchall()

    if not entries:
        return

    # Generate embeddings in batch
    generator = OptimizedEmbeddingGenerator("your-api-key")
    texts = [entry[1] for entry in entries]
    embeddings = await generator.generate_embeddings_batch(texts)

    # Update database
    with cache_manager.conn.cursor() as cur:
        for (cache_id, _), embedding in zip(entries, embeddings):
            cur.execute("""
                UPDATE askwealth.qa_cache
                SET question_embedding = %s::vector
                WHERE cache_id = %s::uuid
            """, [embedding, cache_id])
```

This integration guide provides a complete framework for implementing the caching module in your AskWealth application, with examples for all major use cases and production considerations.
