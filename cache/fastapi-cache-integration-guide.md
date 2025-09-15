# FastAPI Drop-in Cache Integration Guide

## Overview

This guide provides a **drop-in caching solution** for your existing FastAPI application. The implementation adds semantic caching between your rephrased query generation and RAG processing, exactly as requested.

## Files Included

1. **`fastapi-cache-module.sql`** - Minimal database schema based on your existing message structure
2. **`cache_manager.py`** - AsyncPG-based cache manager for FastAPI
3. **`setup_cache.py`** - Setup and initialization script
4. **`fastapi_integration_example.py`** - Complete integration example

## Quick Integration

### 1. Database Setup

```bash
# Initialize the cache module in your existing database
python setup_cache.py \
    --database-url "postgresql://askwealth_rw_dev:hello@localhost:5432/askwealth-dev" \
    --populate

# Verify setup
python setup_cache.py \
    --database-url "postgresql://askwealth_rw_dev:hello@localhost:5432/askwealth-dev" \
    --verify-only
```

### 2. Install Dependencies

```bash
pip install asyncpg  # For PostgreSQL async connection
```

### 3. Integration into Your Existing FastAPI App

**Before (your current flow):**

```
User Question → Rephrased Query → Embedding → RAG → Answer
```

**After (with caching):**

```
User Question → Rephrased Query → Embedding → Check Cache → [Cache Hit: Return Answer]
                                                        → [Cache Miss: RAG → Answer → Cache Result]
```

**Drop-in Integration:**

```python
from cache_manager import QueryCacheManager, initialize_cache, get_cache_manager

# In your FastAPI app startup
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize cache
    database_url = os.getenv("DATABASE_URL")
    await initialize_cache(database_url)
    yield
    # Cleanup on shutdown
    await close_cache()

app = FastAPI(lifespan=lifespan)

# In your existing query endpoint
@app.post("/query")
async def process_query(request: QueryRequest):
    cache_manager = get_cache_manager()

    # Your existing logic
    rephrased_query = await generate_rephrased_query(request.question)
    query_embedding = await generate_embedding(rephrased_query)

    # NEW: Check cache
    cache_hit = await cache_manager.check_cache(query_embedding)
    if cache_hit:
        return {
            "answer": cache_hit.assistant_answer,
            "source": "cache",
            "similarity_score": cache_hit.similarity_score
        }

    # Your existing RAG logic
    rag_result = await process_with_rag(request.question, rephrased_query, query_embedding)

    # NEW: Add to cache
    await cache_manager.add_to_cache(
        user_message_id=user_msg_id,
        assistant_message_id=rag_result["assistant_message_id"],
        rephrased_query=rephrased_query,
        rephrased_query_embedding=query_embedding
    )

    return {"answer": rag_result["answer"], "source": "llm"}
```

## Database Schema

### Cache Table Structure

The implementation uses a minimal table that references your existing message structure:

```sql
askwealth.query_cache_embeddings
├── id (uuid) - Cache entry ID
├── user_message_id (uuid) - References askwealth.message
├── assistant_message_id (uuid) - References askwealth.message
├── rephrased_query (text) - The LLM-generated rephrased query
├── rephrased_query_embedding (vector) - Embedding for similarity search
├── cache_hits (integer) - Usage tracking
└── created_at (timestamp) - Cache entry creation time
```

### Q&A Extraction View

Based on your existing query pattern (from the attachment), the view extracts:

- User questions from message parts
- Assistant answers from message parts
- Rephrased queries from message annotations (specifically `debug.rephrase_question_result`)
- Only includes messages where `debug.relevant_rephrase_question_result.relevant = 'true'`

## Key Features

### 🎯 **Exact Flow Integration**

- Plugs in between embedding generation and RAG processing
- Uses your existing rephrased queries for cache matching
- Maintains full compatibility with your current message structure

### 🚀 **Performance**

- Vector similarity search using pgvector (cosine similarity)
- Configurable similarity threshold (default: 0.85)
- Async/await compatible with FastAPI
- Connection pooling for scalability

### 🔧 **Configuration**

- Runtime configuration updates via API
- Cache size limits and cleanup
- Enable/disable caching without code changes

### 📊 **Monitoring**

- Cache hit/miss statistics
- Performance metrics
- Usage tracking per cached entry

## API Usage Examples

### Basic Query Processing

```python
# Check cache before RAG
cache_hit = await cache_manager.check_cache(embedding)
if cache_hit:
    # Cache hit - return immediately
    return CachedResponse(
        answer=cache_hit.assistant_answer,
        source="cache",
        similarity_score=cache_hit.similarity_score
    )

# Cache miss - proceed with RAG and cache result
llm_result = await your_rag_function(question, rephrased_query)
cache_id = await cache_manager.add_to_cache(
    user_message_id, assistant_message_id,
    rephrased_query, embedding
)
```

### Cache Management

```python
# Get cache statistics
stats = await cache_manager.get_cache_stats()
# Returns: total_entries, entries_with_embeddings, total_cache_hits, etc.

# Update configuration
await cache_manager.update_config(
    similarity_threshold=0.90,  # More strict matching
    max_cache_entries=10000    # Increase cache size
)

# Cleanup old entries
deleted = await cache_manager.cleanup_cache()
```

## Configuration Options

| Setting                | Default | Description                                        |
| ---------------------- | ------- | -------------------------------------------------- |
| `similarity_threshold` | 0.85    | Minimum cosine similarity for cache hits (0.0-1.0) |
| `cache_enabled`        | true    | Global cache enable/disable                        |
| `max_cache_entries`    | 5000    | Maximum cached Q&A pairs                           |

## Monitoring Endpoints

```python
# Cache statistics
GET /cache/stats
{
  "total_entries": 1250,
  "entries_with_embeddings": 1200,
  "total_cache_hits": 450,
  "avg_hits_per_entry": 2.3
}

# Update configuration
PUT /cache/config
{
  "similarity_threshold": 0.90,
  "cache_enabled": true
}

# Manual cleanup
POST /cache/cleanup
{"deleted_entries": 50}
```

## Migration from Your Current Setup

### Step 1: Install and Setup

```bash
# Run the SQL setup
python setup_cache.py --database-url "$DATABASE_URL" --populate
```

### Step 2: Add Cache Manager to Your App

```python
# Add to your existing FastAPI app
from cache_manager import initialize_cache, get_cache_manager

# Initialize in lifespan or startup event
await initialize_cache(database_url)
```

### Step 3: Update Your Query Handler

```python
# Add cache check before RAG
cache_hit = await get_cache_manager().check_cache(embedding)
if cache_hit:
    return cache_hit.assistant_answer

# Add cache storage after RAG
await get_cache_manager().add_to_cache(...)
```

### Step 4: Populate Historical Data

```python
# Populate cache from existing Q&A pairs
populated = await cache_manager.populate_from_existing()
print(f"Populated {populated} historical Q&A pairs")
```

## Performance Characteristics

### Cache Hit Scenarios

- **Latency**: ~5-10ms (vs 1000-5000ms for LLM calls)
- **Cost**: Near zero (vs $0.001-0.01 per LLM call)
- **Accuracy**: Configurable similarity threshold

### Cache Miss Scenarios

- **Overhead**: ~1-2ms additional latency
- **Storage**: ~8KB per cached Q&A pair
- **Processing**: Async, non-blocking

## Example Performance Gains

With a 30% cache hit rate:

- **Latency Reduction**: 30% of queries ~100x faster
- **Cost Savings**: 30% reduction in LLM API costs
- **Capacity**: 30% more queries with same infrastructure

## Troubleshooting

### Common Issues

1. **No Cache Hits**

   - Check if embeddings are being generated and stored
   - Verify similarity threshold isn't too high
   - Ensure rephrased queries are consistent

2. **High Memory Usage**

   - Monitor cache size with `/cache/stats`
   - Adjust `max_cache_entries` configuration
   - Run periodic cleanup

3. **Slow Cache Lookups**
   - Verify vector index is created
   - Check connection pool settings
   - Monitor database performance

### Debug Commands

```python
# Check cache setup
stats = await cache_manager.get_cache_stats()
print(f"Cache entries: {stats['total_entries']}")
print(f"With embeddings: {stats['entries_with_embeddings']}")

# Test similarity search
results = await cache_manager.check_cache(test_embedding, threshold=0.5)
if results:
    print(f"Found similar query: {results.similarity_score}")
```

## Production Considerations

### Security

- Use read-only database users for cache lookups
- Sanitize user inputs before caching
- Consider data retention policies

### Scalability

- Monitor cache hit rates and adjust thresholds
- Consider cache partitioning for multi-tenant setups
- Implement cache warming for popular queries

### Maintenance

- Schedule periodic cache cleanup
- Monitor embedding storage growth
- Update vector indexes as data grows

This drop-in implementation integrates seamlessly with your existing FastAPI application while providing significant performance improvements through intelligent semantic caching.
