# FastAPI Query Cache - Alembic Migration

This directory contains Alembic migration files that follow the standard Alembic template format to set up the query cache system in your FastAPI application.

## What's Included

1. **`create_cache_migration.py`** - Generator script for creating custom migration files
2. **`sample_alembic_migration.py`** - Ready-to-use migration file template
3. **`20250915_140208_add_fastapi_cache_system.py`** - Generated example migration

## Migration Format

The migrations now follow the standard Alembic `script.py.mako` template format:

```python
"""Migration description

Revision ID: timestamp_name
Revises: previous_revision_id
Create Date: 2025-09-15T14:02:08

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = 'timestamp_name'
down_revision: Union[str, None] = None  # Set this to your latest migration ID
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

def upgrade() -> None:
    """Upgrade operations."""
    pass

def downgrade() -> None:
    """Downgrade operations."""
    pass
```

1. **Copy the migration file** to your alembic versions directory:

   ```bash
   cp sample_alembic_migration.py /path/to/your/app/alembic/versions/20250915_142000_add_query_cache_system.py
   ```

2. **Update the down_revision** in the copied file:

   ```python
   # In the migration file, replace:
   down_revision = None  # ⚠️ IMPORTANT: Set this to your latest migration ID

   # With your actual latest migration ID:
   down_revision = 'your_latest_migration_id_here'
   ```

3. **Run the migration**:
   ```bash
   alembic upgrade head
   ```

### Option 2: Generate a Custom Migration

1. **Run the generator script**:

   ```bash
   python create_cache_migration.py --revision-name "add_query_cache_system" --output-dir "path/to/your/alembic/versions"
   ```

2. **Follow the prompts** to update the down_revision and run the migration.

## What the Migration Creates

### 📊 Database Objects

1. **`askwealth.query_cache_config`** - Configuration table for cache settings
2. **`askwealth.query_cache_embeddings`** - Main cache table with vector embeddings
3. **`askwealth.v_cached_qa_pairs`** - View to extract Q&A pairs from your message structure
4. **Vector indexes** - For fast similarity search
5. **Helper functions** - For cache operations

### 🎯 Key Features

- **Vector similarity search** using pgvector for semantic matching
- **Configurable thresholds** for cache hit sensitivity
- **Automatic cleanup** to maintain cache size limits
- **Performance monitoring** with hit tracking
- **Integration with existing message structure**

## After Migration

### 1. Install Dependencies

```bash
pip install asyncpg  # For async PostgreSQL connection
```

### 2. Integration Steps

1. **Copy the cache manager** to your FastAPI app:

   ```bash
   cp cache/cache_manager.py /path/to/your/app/
   ```

2. **Initialize in your FastAPI app**:

   ```python
   from cache_manager import initialize_cache, get_cache_manager

   @app.on_event("startup")
   async def startup():
       await initialize_cache(DATABASE_URL)
   ```

3. **Add cache checks** to your query processing:

   ```python
   # Before RAG processing
   cache_hit = await get_cache_manager().check_cache(embedding)
   if cache_hit:
       return cache_hit.assistant_answer

   # After RAG processing
   await get_cache_manager().add_to_cache(
       user_msg_id, assistant_msg_id, rephrased_query, embedding
   )
   ```

### 3. Populate Historical Data (Optional)

```python
# Populate cache from existing Q&A pairs
populated = await get_cache_manager().populate_from_existing()
print(f"Populated {populated} historical Q&A pairs")
```

## Configuration

The cache system is configurable via the `askwealth.query_cache_config` table:

| Setting                | Default | Description                                        |
| ---------------------- | ------- | -------------------------------------------------- |
| `similarity_threshold` | 0.85    | Minimum cosine similarity for cache hits (0.0-1.0) |
| `cache_enabled`        | true    | Global cache enable/disable                        |
| `max_cache_entries`    | 5000    | Maximum cached Q&A pairs                           |

## Monitoring

### Check Cache Statistics

```python
stats = await get_cache_manager().get_cache_stats()
print(f"Total entries: {stats['total_entries']}")
print(f"Cache hits: {stats['total_cache_hits']}")
```

### Update Configuration

```python
await get_cache_manager().update_config(
    similarity_threshold=0.90,  # More strict matching
    max_cache_entries=10000     # Increase cache size
)
```

## Prerequisites

- PostgreSQL with pgvector extension
- Existing `askwealth.message` table structure
- Alembic set up in your FastAPI project

## Support

For detailed integration examples, see:

- `cache/fastapi-cache-integration-guide.md` - Complete integration guide
- `cache/fastapi_integration_example.py` - Working example
- `cache/cache_manager.py` - Core cache manager implementation

## Performance Impact

- **Cache hits**: ~5-10ms (vs 1000-5000ms for LLM calls)
- **Cache misses**: ~1-2ms additional overhead
- **Storage**: ~8KB per cached Q&A pair
- **Typical hit rates**: 20-40% after initial warmup period
