-- AskWealth Caching Module
-- This module implements question-answer caching with semantic similarity matching
-- to reduce redundant LLM calls by reusing previously computed answers.

-- ================================================================
-- 1. CACHE CONFIGURATION TABLE
-- ================================================================

-- Table to store caching configuration parameters
CREATE TABLE IF NOT EXISTS askwealth.cache_config (
    config_key varchar(100) NOT NULL,
    config_value jsonb NOT NULL,
    description text,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT cache_config_pkey PRIMARY KEY (config_key)
);

-- Insert default configuration values
INSERT INTO askwealth.cache_config (config_key, config_value, description) 
VALUES 
    ('similarity_threshold', '0.85', 'Minimum cosine similarity threshold for cache hits (0.0 to 1.0)'),
    ('cache_ttl_days', '30', 'Number of days before cache entries expire'),
    ('max_cache_size', '10000', 'Maximum number of entries to keep in cache'),
    ('enable_cache', 'true', 'Global flag to enable/disable caching'),
    ('rephrasing_enabled', 'true', 'Whether to use rephrased queries for matching')
ON CONFLICT (config_key) DO NOTHING;

-- ================================================================
-- 2. QUESTION-ANSWER CACHE TABLE
-- ================================================================

-- Main cache table storing question-answer pairs with embeddings
CREATE TABLE IF NOT EXISTS askwealth.qa_cache (
    cache_id uuid NOT NULL DEFAULT gen_random_uuid(),
    thread_id uuid NOT NULL,
    user_message_id uuid NOT NULL,
    assistant_message_id uuid NOT NULL,
    
    -- Question data
    original_question text NOT NULL,
    rephrased_question text,
    question_embedding extensions.vector(1536), -- Assuming OpenAI ada-002 dimensions
    
    -- Answer data
    answer_text text NOT NULL,
    answer_metadata jsonb,
    
    -- Cache metadata
    cache_hits integer NOT NULL DEFAULT 0,
    last_hit_at timestamp,
    quality_score decimal(3,2), -- Optional: quality score based on feedback
    
    -- Audit fields
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(50) NOT NULL DEFAULT 'system',
    
    CONSTRAINT qa_cache_pkey PRIMARY KEY (cache_id),
    CONSTRAINT qa_cache_thread_fkey FOREIGN KEY (thread_id) REFERENCES askwealth.thread(thread_id) ON DELETE CASCADE,
    CONSTRAINT qa_cache_user_msg_fkey FOREIGN KEY (user_message_id) REFERENCES askwealth.message(message_id) ON DELETE CASCADE,
    CONSTRAINT qa_cache_assistant_msg_fkey FOREIGN KEY (assistant_message_id) REFERENCES askwealth.message(message_id) ON DELETE CASCADE
);

-- Create index for vector similarity search
CREATE INDEX IF NOT EXISTS idx_qa_cache_embedding 
ON askwealth.qa_cache USING ivfflat (question_embedding vector_cosine_ops)
WITH (lists = 100);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_qa_cache_thread_id ON askwealth.qa_cache(thread_id);
CREATE INDEX IF NOT EXISTS idx_qa_cache_created_at ON askwealth.qa_cache(created_at);
CREATE INDEX IF NOT EXISTS idx_qa_cache_hits ON askwealth.qa_cache(cache_hits DESC);

-- ================================================================
-- 3. QUESTION-ANSWER EXTRACTION VIEW
-- ================================================================

-- View to extract question-answer pairs from the message table
CREATE OR REPLACE VIEW askwealth.v_qa_pairs AS
WITH message_pairs AS (
    SELECT 
        t.thread_id,
        t.title as thread_title,
        t.created_by as thread_creator,
        
        -- User message (question)
        user_msg.message_id as user_message_id,
        user_msg.parts as user_parts,
        user_msg.annotations as user_annotations,
        user_msg.created_at as question_time,
        
        -- Assistant message (answer) - next message in the thread
        asst_msg.message_id as assistant_message_id,
        asst_msg.parts as assistant_parts,
        asst_msg.annotations as assistant_annotations,
        asst_msg.created_at as answer_time,
        
        -- Extract text content from JSONB parts
        (
            SELECT string_agg(
                CASE 
                    WHEN jsonb_typeof(part) = 'object' AND part ? 'text' THEN part->>'text'
                    WHEN jsonb_typeof(part) = 'string' THEN part#>>'{}'
                    ELSE part::text
                END, ' '
            )
            FROM jsonb_array_elements(user_msg.parts) as part
            WHERE part IS NOT NULL
        ) as original_question,
        
        (
            SELECT string_agg(
                CASE 
                    WHEN jsonb_typeof(part) = 'object' AND part ? 'text' THEN part->>'text'
                    WHEN jsonb_typeof(part) = 'string' THEN part#>>'{}'
                    ELSE part::text
                END, ' '
            )
            FROM jsonb_array_elements(asst_msg.parts) as part
            WHERE part IS NOT NULL
        ) as answer_text,
        
        -- Extract rephrased question from annotations if available
        COALESCE(
            user_msg.annotations->>'rephrased_query',
            user_msg.annotations->'rephrasing'->>'query',
            user_msg.annotations->'metadata'->>'rephrased_question'
        ) as rephrased_question,
        
        ROW_NUMBER() OVER (
            PARTITION BY t.thread_id, user_msg.message_id 
            ORDER BY asst_msg.created_at ASC
        ) as response_rank
        
    FROM askwealth.thread t
    JOIN askwealth.message user_msg ON user_msg.thread_id = t.thread_id 
        AND user_msg.role = 'user'
    JOIN askwealth.message asst_msg ON asst_msg.thread_id = t.thread_id 
        AND asst_msg.role = 'assistant'
        AND asst_msg.created_at > user_msg.created_at
)
SELECT 
    thread_id,
    thread_title,
    thread_creator,
    user_message_id,
    assistant_message_id,
    original_question,
    rephrased_question,
    answer_text,
    user_annotations,
    assistant_annotations,
    question_time,
    answer_time
FROM message_pairs 
WHERE response_rank = 1  -- Take the first assistant response after each user question
    AND original_question IS NOT NULL 
    AND answer_text IS NOT NULL
    AND length(trim(original_question)) > 10  -- Filter out very short questions
    AND length(trim(answer_text)) > 10;       -- Filter out very short answers

-- ================================================================
-- 4. CACHE LOOKUP FUNCTIONS
-- ================================================================

-- Function to find similar cached questions and return the best match
CREATE OR REPLACE FUNCTION askwealth.find_cached_answer(
    p_question_embedding extensions.vector,
    p_similarity_threshold decimal DEFAULT NULL
)
RETURNS TABLE (
    cache_id uuid,
    original_question text,
    rephrased_question text,
    answer_text text,
    answer_metadata jsonb,
    similarity_score decimal,
    cache_hits integer,
    created_at timestamp
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_threshold decimal;
    v_cache_enabled boolean;
BEGIN
    -- Get configuration values
    SELECT (config_value::text)::decimal INTO v_threshold
    FROM askwealth.cache_config 
    WHERE config_key = 'similarity_threshold';
    
    SELECT (config_value::text)::boolean INTO v_cache_enabled
    FROM askwealth.cache_config 
    WHERE config_key = 'enable_cache';
    
    -- Use provided threshold or default
    v_threshold := COALESCE(p_similarity_threshold, v_threshold, 0.85);
    
    -- Return empty if cache is disabled
    IF NOT COALESCE(v_cache_enabled, true) THEN
        RETURN;
    END IF;
    
    -- Find the most similar cached question above threshold
    RETURN QUERY
    SELECT 
        qc.cache_id,
        qc.original_question,
        qc.rephrased_question,
        qc.answer_text,
        qc.answer_metadata,
        (1 - (qc.question_embedding <=> p_question_embedding))::decimal as similarity_score,
        qc.cache_hits,
        qc.created_at
    FROM askwealth.qa_cache qc
    WHERE qc.question_embedding IS NOT NULL
        AND (1 - (qc.question_embedding <=> p_question_embedding)) >= v_threshold
    ORDER BY qc.question_embedding <=> p_question_embedding ASC
    LIMIT 1;
END;
$$;

-- Function to update cache hit statistics
CREATE OR REPLACE FUNCTION askwealth.record_cache_hit(p_cache_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE askwealth.qa_cache 
    SET 
        cache_hits = cache_hits + 1,
        last_hit_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE cache_id = p_cache_id;
    
    RETURN FOUND;
END;
$$;

-- ================================================================
-- 5. CACHE POPULATION FUNCTIONS
-- ================================================================

-- Function to add a new question-answer pair to cache
CREATE OR REPLACE FUNCTION askwealth.add_to_cache(
    p_thread_id uuid,
    p_user_message_id uuid,
    p_assistant_message_id uuid,
    p_original_question text,
    p_rephrased_question text DEFAULT NULL,
    p_question_embedding extensions.vector DEFAULT NULL,
    p_answer_text text,
    p_answer_metadata jsonb DEFAULT NULL,
    p_created_by varchar(50) DEFAULT 'system'
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_cache_id uuid;
    v_cache_enabled boolean;
BEGIN
    -- Check if caching is enabled
    SELECT (config_value::text)::boolean INTO v_cache_enabled
    FROM askwealth.cache_config 
    WHERE config_key = 'enable_cache';
    
    IF NOT COALESCE(v_cache_enabled, true) THEN
        RETURN NULL;
    END IF;
    
    -- Insert new cache entry
    INSERT INTO askwealth.qa_cache (
        thread_id,
        user_message_id,
        assistant_message_id,
        original_question,
        rephrased_question,
        question_embedding,
        answer_text,
        answer_metadata,
        created_by
    ) VALUES (
        p_thread_id,
        p_user_message_id,
        p_assistant_message_id,
        p_original_question,
        p_rephrased_question,
        p_question_embedding,
        p_answer_text,
        p_answer_metadata,
        p_created_by
    )
    RETURNING cache_id INTO v_cache_id;
    
    RETURN v_cache_id;
END;
$$;

-- Function to populate cache from existing Q&A pairs
CREATE OR REPLACE FUNCTION askwealth.populate_cache_from_history()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer := 0;
    qa_record record;
BEGIN
    -- Insert Q&A pairs that are not already in cache
    FOR qa_record IN 
        SELECT DISTINCT
            vqa.thread_id,
            vqa.user_message_id,
            vqa.assistant_message_id,
            vqa.original_question,
            vqa.rephrased_question,
            vqa.answer_text,
            vqa.user_annotations,
            vqa.assistant_annotations
        FROM askwealth.v_qa_pairs vqa
        LEFT JOIN askwealth.qa_cache qc ON qc.user_message_id = vqa.user_message_id
        WHERE qc.cache_id IS NULL  -- Not already cached
    LOOP
        PERFORM askwealth.add_to_cache(
            qa_record.thread_id,
            qa_record.user_message_id,
            qa_record.assistant_message_id,
            qa_record.original_question,
            qa_record.rephrased_question,
            NULL, -- embedding will be added separately
            qa_record.answer_text,
            jsonb_build_object(
                'user_annotations', qa_record.user_annotations,
                'assistant_annotations', qa_record.assistant_annotations
            )
        );
        
        v_count := v_count + 1;
    END LOOP;
    
    RETURN v_count;
END;
$$;

-- ================================================================
-- 6. CACHE MAINTENANCE FUNCTIONS
-- ================================================================

-- Function to clean up expired cache entries
CREATE OR REPLACE FUNCTION askwealth.cleanup_expired_cache()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_ttl_days integer;
    v_deleted_count integer;
BEGIN
    -- Get TTL configuration
    SELECT (config_value::text)::integer INTO v_ttl_days
    FROM askwealth.cache_config 
    WHERE config_key = 'cache_ttl_days';
    
    v_ttl_days := COALESCE(v_ttl_days, 30);
    
    -- Delete expired entries
    DELETE FROM askwealth.qa_cache 
    WHERE created_at < CURRENT_TIMESTAMP - (v_ttl_days || ' days')::interval;
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    RETURN v_deleted_count;
END;
$$;

-- Function to enforce cache size limits
CREATE OR REPLACE FUNCTION askwealth.enforce_cache_size_limit()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_size integer;
    v_current_count integer;
    v_deleted_count integer;
BEGIN
    -- Get max size configuration
    SELECT (config_value::text)::integer INTO v_max_size
    FROM askwealth.cache_config 
    WHERE config_key = 'max_cache_size';
    
    v_max_size := COALESCE(v_max_size, 10000);
    
    -- Get current count
    SELECT COUNT(*) INTO v_current_count FROM askwealth.qa_cache;
    
    -- Delete oldest entries if over limit
    IF v_current_count > v_max_size THEN
        DELETE FROM askwealth.qa_cache 
        WHERE cache_id IN (
            SELECT cache_id 
            FROM askwealth.qa_cache 
            ORDER BY last_hit_at NULLS FIRST, created_at ASC
            LIMIT (v_current_count - v_max_size)
        );
        
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    ELSE
        v_deleted_count := 0;
    END IF;
    
    RETURN v_deleted_count;
END;
$$;

-- ================================================================
-- 7. CACHE STATISTICS AND MONITORING
-- ================================================================

-- View for cache statistics and monitoring
CREATE OR REPLACE VIEW askwealth.v_cache_stats AS
SELECT 
    COUNT(*) as total_entries,
    COUNT(CASE WHEN question_embedding IS NOT NULL THEN 1 END) as entries_with_embeddings,
    COUNT(CASE WHEN cache_hits > 0 THEN 1 END) as entries_with_hits,
    COALESCE(SUM(cache_hits), 0) as total_cache_hits,
    COALESCE(AVG(cache_hits), 0)::decimal(10,2) as avg_hits_per_entry,
    MIN(created_at) as oldest_entry,
    MAX(created_at) as newest_entry,
    MAX(last_hit_at) as last_cache_hit,
    COUNT(CASE WHEN created_at > CURRENT_DATE - INTERVAL '7 days' THEN 1 END) as entries_last_7_days,
    COUNT(CASE WHEN created_at > CURRENT_DATE - INTERVAL '30 days' THEN 1 END) as entries_last_30_days
FROM askwealth.qa_cache;

-- Function to get cache performance metrics
CREATE OR REPLACE FUNCTION askwealth.get_cache_metrics(
    p_days_back integer DEFAULT 7
)
RETURNS TABLE (
    metric_name text,
    metric_value text,
    description text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_entries integer;
    v_hit_rate decimal;
    v_config record;
BEGIN
    -- Total entries
    SELECT COUNT(*) INTO v_total_entries FROM askwealth.qa_cache;
    
    RETURN QUERY VALUES 
        ('total_cache_entries', v_total_entries::text, 'Total number of cached Q&A pairs'),
        ('cache_size_mb', 
         (pg_total_relation_size('askwealth.qa_cache') / 1024.0 / 1024.0)::decimal(10,2)::text, 
         'Cache table size in MB');
    
    -- Cache hit rate (if we track queries somewhere)
    -- This would need to be implemented based on your application's query logging
    
    -- Configuration values
    FOR v_config IN 
        SELECT config_key, config_value::text as value, description
        FROM askwealth.cache_config
        ORDER BY config_key
    LOOP
        RETURN QUERY VALUES (v_config.config_key, v_config.value, v_config.description);
    END LOOP;
END;
$$;

-- ================================================================
-- 8. TRIGGER FOR AUTO-UPDATING TIMESTAMPS
-- ================================================================

-- Function to update the updated_at timestamp
CREATE OR REPLACE FUNCTION askwealth.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Trigger for qa_cache table
CREATE TRIGGER trigger_qa_cache_updated_at
    BEFORE UPDATE ON askwealth.qa_cache
    FOR EACH ROW
    EXECUTE FUNCTION askwealth.update_updated_at_column();

-- Trigger for cache_config table  
CREATE TRIGGER trigger_cache_config_updated_at
    BEFORE UPDATE ON askwealth.cache_config
    FOR EACH ROW
    EXECUTE FUNCTION askwealth.update_updated_at_column();

-- ================================================================
-- 9. EXAMPLE USAGE QUERIES
-- ================================================================

/*
-- Example 1: Populate cache from existing messages
SELECT askwealth.populate_cache_from_history();

-- Example 2: Find similar cached answer
SELECT * FROM askwealth.find_cached_answer('[0.1, 0.2, 0.3, ...]'::vector);

-- Example 3: Add new Q&A to cache
SELECT askwealth.add_to_cache(
    'thread-uuid'::uuid,
    'user-msg-uuid'::uuid, 
    'assistant-msg-uuid'::uuid,
    'What is the weather today?',
    'weather forecast today',
    '[0.1, 0.2, 0.3, ...]'::vector,
    'Today will be sunny with temperatures around 75°F.',
    '{"confidence": 0.95}'::jsonb
);

-- Example 4: Record a cache hit
SELECT askwealth.record_cache_hit('cache-uuid'::uuid);

-- Example 5: View cache statistics
SELECT * FROM askwealth.v_cache_stats;

-- Example 6: Get cache metrics
SELECT * FROM askwealth.get_cache_metrics(30);

-- Example 7: Clean up expired entries
SELECT askwealth.cleanup_expired_cache();

-- Example 8: Enforce size limits
SELECT askwealth.enforce_cache_size_limit();

-- Example 9: View all Q&A pairs available for caching
SELECT * FROM askwealth.v_qa_pairs LIMIT 10;

-- Example 10: Update cache configuration
UPDATE askwealth.cache_config 
SET config_value = '0.90' 
WHERE config_key = 'similarity_threshold';
*/