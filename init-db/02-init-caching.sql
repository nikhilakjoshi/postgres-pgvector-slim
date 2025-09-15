-- AskWealth Caching Module Initialization Script
-- This script should be run after the main database initialization
-- to set up the caching module components.

-- ================================================================
-- CACHING MODULE INITIALIZATION
-- ================================================================

\echo 'Initializing AskWealth Caching Module...'

-- Load the main caching module
\i caching-module.sql

-- ================================================================
-- INITIAL DATA POPULATION
-- ================================================================

\echo 'Populating cache from existing message history...'

-- Populate cache with existing Q&A pairs
DO $$
DECLARE
    v_populated_count integer;
BEGIN
    SELECT askwealth.populate_cache_from_history() INTO v_populated_count;
    RAISE NOTICE 'Populated % Q&A pairs into cache from message history', v_populated_count;
END;
$$;

-- ================================================================
-- PERFORMANCE OPTIMIZATIONS
-- ================================================================

\echo 'Applying performance optimizations...'

-- Analyze tables for better query planning
ANALYZE askwealth.qa_cache;
ANALYZE askwealth.cache_config;

-- Update statistics for the view
ANALYZE askwealth.message;
ANALYZE askwealth.thread;

-- ================================================================
-- VERIFICATION
-- ================================================================

\echo 'Verifying caching module installation...'

-- Check if all components are created
DO $$
DECLARE
    v_config_count integer;
    v_cache_count integer;
    v_view_count integer;
BEGIN
    -- Check configuration table
    SELECT COUNT(*) INTO v_config_count FROM askwealth.cache_config;
    RAISE NOTICE 'Cache configuration entries: %', v_config_count;
    
    -- Check cache table
    SELECT COUNT(*) INTO v_cache_count FROM askwealth.qa_cache;
    RAISE NOTICE 'Cache entries: %', v_cache_count;
    
    -- Check if view works
    SELECT COUNT(*) INTO v_view_count FROM askwealth.v_qa_pairs LIMIT 1000;
    RAISE NOTICE 'Q&A pairs available for caching: %', v_view_count;
    
    IF v_config_count = 0 THEN
        RAISE WARNING 'Cache configuration is empty!';
    END IF;
    
    RAISE NOTICE 'Caching module verification completed';
END;
$$;

-- Display current cache statistics
\echo 'Current cache statistics:'
SELECT * FROM askwealth.v_cache_stats;

-- Display configuration
\echo 'Cache configuration:'
SELECT config_key, config_value, description 
FROM askwealth.cache_config 
ORDER BY config_key;

\echo 'AskWealth Caching Module initialization completed successfully!'
\echo ''
\echo 'Next steps:'
\echo '1. Generate embeddings for cached questions (requires application-level integration)'
\echo '2. Configure similarity threshold based on your requirements'
\echo '3. Set up periodic maintenance jobs'
\echo '4. Integrate cache lookup into your application query flow'