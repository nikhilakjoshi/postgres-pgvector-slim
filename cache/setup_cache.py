#!/usr/bin/env python3
"""
Setup script for FastAPI Query Cache Module

This script initializes the caching module in your existing database
and optionally populates it with historical Q&A pairs.
"""

import asyncio
import asyncpg
import logging
from pathlib import Path
from typing import Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class CacheSetup:
    """Setup utility for the query cache module."""

    def __init__(self, database_url: str):
        self.database_url = database_url

    async def run_sql_file(self, sql_file: Path, conn: asyncpg.Connection) -> None:
        """Execute SQL file."""
        logger.info(f"Executing {sql_file.name}...")

        sql_content = sql_file.read_text()

        # Split by statements and execute
        statements = [stmt.strip() for stmt in sql_content.split(";") if stmt.strip()]

        for stmt in statements:
            if stmt.lower().startswith(("create", "insert", "alter", "drop")):
                try:
                    await conn.execute(stmt)
                except Exception as e:
                    logger.warning(f"Statement failed (might be expected): {e}")

    async def setup_database(self, sql_file_path: Optional[str] = None) -> bool:
        """Set up the cache database schema."""
        try:
            conn = await asyncpg.connect(self.database_url)

            # Use provided SQL file or default
            if sql_file_path:
                sql_file = Path(sql_file_path)
            else:
                sql_file = Path(__file__).parent / "fastapi-cache-module.sql"

            if not sql_file.exists():
                logger.error(f"SQL file not found: {sql_file}")
                return False

            await self.run_sql_file(sql_file, conn)

            logger.info("Database setup completed successfully")
            await conn.close()
            return True

        except Exception as e:
            logger.error(f"Database setup failed: {e}")
            return False

    async def populate_cache(self) -> int:
        """Populate cache from existing Q&A pairs."""
        try:
            conn = await asyncpg.connect(self.database_url)

            # Populate cache entries (without embeddings)
            populated_count = await conn.fetchval(
                """
                SELECT askwealth.populate_cache_from_existing()
            """
            )

            logger.info(f"Populated {populated_count} Q&A pairs into cache")

            # Check what needs embeddings
            pending_count = await conn.fetchval(
                """
                SELECT COUNT(*) FROM askwealth.query_cache_embeddings 
                WHERE rephrased_query_embedding IS NULL
            """
            )

            logger.info(f"{pending_count} entries need embeddings to be generated")

            await conn.close()
            return populated_count or 0

        except Exception as e:
            logger.error(f"Cache population failed: {e}")
            return 0

    async def verify_setup(self) -> dict:
        """Verify the setup and return status."""
        try:
            conn = await asyncpg.connect(self.database_url)

            # Check tables exist
            tables = await conn.fetch(
                """
                SELECT table_name FROM information_schema.tables 
                WHERE table_schema = 'askwealth' 
                AND table_name IN ('query_cache_config', 'query_cache_embeddings')
            """
            )

            # Check view exists
            views = await conn.fetch(
                """
                SELECT table_name FROM information_schema.views 
                WHERE table_schema = 'askwealth' 
                AND table_name = 'v_cached_qa_pairs'
            """
            )

            # Check functions exist
            functions = await conn.fetch(
                """
                SELECT routine_name FROM information_schema.routines 
                WHERE routine_schema = 'askwealth' 
                AND routine_name IN ('find_similar_cached_query', 'add_cache_entry')
            """
            )

            # Get cache statistics
            stats = await conn.fetchrow(
                """
                SELECT 
                    COUNT(*) as total_entries,
                    COUNT(CASE WHEN rephrased_query_embedding IS NOT NULL THEN 1 END) as entries_with_embeddings
                FROM askwealth.query_cache_embeddings
            """
            )

            # Get available Q&A pairs
            available_pairs = await conn.fetchval(
                """
                SELECT COUNT(*) FROM askwealth.v_cached_qa_pairs
            """
            )

            await conn.close()

            return {
                "tables_created": len(tables) == 2,
                "view_created": len(views) == 1,
                "functions_created": len(functions) >= 2,
                "cache_entries": stats["total_entries"] if stats else 0,
                "entries_with_embeddings": (
                    stats["entries_with_embeddings"] if stats else 0
                ),
                "available_qa_pairs": available_pairs or 0,
                "setup_complete": len(tables) == 2
                and len(views) == 1
                and len(functions) >= 2,
            }

        except Exception as e:
            logger.error(f"Verification failed: {e}")
            return {"setup_complete": False, "error": str(e)}


async def main():
    """Main setup function."""
    import argparse

    parser = argparse.ArgumentParser(description="Setup FastAPI Query Cache Module")
    parser.add_argument(
        "--database-url", required=True, help="PostgreSQL connection URL"
    )
    parser.add_argument("--sql-file", help="Path to SQL setup file")
    parser.add_argument(
        "--populate", action="store_true", help="Populate cache from existing data"
    )
    parser.add_argument("--verify-only", action="store_true", help="Only verify setup")

    args = parser.parse_args()

    setup = CacheSetup(args.database_url)

    if args.verify_only:
        logger.info("Verifying cache setup...")
        status = await setup.verify_setup()

        print("\n=== Cache Setup Status ===")
        for key, value in status.items():
            print(f"{key}: {value}")

        if status.get("setup_complete"):
            print("\n✅ Cache module is properly set up!")
        else:
            print("\n❌ Cache module setup is incomplete")

        return

    # Setup database schema
    logger.info("Setting up cache database schema...")
    if not await setup.setup_database(args.sql_file):
        logger.error("Database setup failed")
        return

    # Populate if requested
    if args.populate:
        logger.info("Populating cache from existing data...")
        populated = await setup.populate_cache()
        print(f"Populated {populated} Q&A pairs")

    # Verify setup
    logger.info("Verifying setup...")
    status = await setup.verify_setup()

    print("\n=== Setup Complete ===")
    print(f"Cache entries: {status.get('cache_entries', 0)}")
    print(f"Available Q&A pairs: {status.get('available_qa_pairs', 0)}")
    print(f"Entries with embeddings: {status.get('entries_with_embeddings', 0)}")

    if status.get("setup_complete"):
        print("\n✅ Cache module setup successful!")
        print("\nNext steps:")
        print("1. Generate embeddings for cached queries")
        print("2. Integrate cache_manager.py into your FastAPI app")
        print("3. Update your query processing flow")
    else:
        print("\n❌ Setup incomplete - check logs for errors")


if __name__ == "__main__":
    asyncio.run(main())
