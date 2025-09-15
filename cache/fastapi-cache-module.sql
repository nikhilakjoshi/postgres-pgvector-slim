-- Minimal Caching Module for FastAPI Integration
-- Drop-in implementation based on existing message structure

-- ================================================================
-- 1. SIMPLE CACHE CONFIGURATION
-- ================================================================

CREATE TABLE IF NOT EXISTS askwealth.query_cache_config (
    key varchar(50) PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamp DEFAULT CURRENT_TIMESTAMP
);

-- Insert basic configuration
INSERT INTO askwealth.query_cache_config (key, value) VALUES 
    ('similarity_threshold', '0.85'),
    ('cache_enabled', 'true'),
    ('max_cache_entries', '5000')
ON CONFLICT (key) DO NOTHING;

-- ================================================================
-- 2. CACHE EMBEDDINGS TABLE
-- ================================================================

CREATE TABLE IF NOT EXISTS askwealth.query_cache_embeddings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_message_id uuid NOT NULL REFERENCES askwealth.message(message_id) ON DELETE CASCADE,
    assistant_message_id uuid NOT NULL REFERENCES askwealth.message(message_id) ON DELETE CASCADE,
    rephrased_query text NOT NULL,
    rephrased_query_embedding extensions.vector(1536), -- OpenAI ada-002 dimensions
    cache_hits integer DEFAULT 0,
    last_accessed timestamp,
    created_at timestamp DEFAULT CURRENT_TIMESTAMP,
    
    -- Ensure unique pairing
    UNIQUE(user_message_id, assistant_message_id)
);

-- Create vector similarity index
CREATE INDEX IF NOT EXISTS idx_query_cache_embeddings_vector 
ON askwealth.query_cache_embeddings 
USING ivfflat (rephrased_query_embedding vector_cosine_ops)
WITH (lists = 100);

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_query_cache_embeddings_user_msg 
ON askwealth.query_cache_embeddings(user_message_id);

CREATE INDEX IF NOT EXISTS idx_query_cache_embeddings_hits 
ON askwealth.query_cache_embeddings(cache_hits DESC);

-- ================================================================
-- 3. Q&A VIEW BASED ON YOUR EXISTING PATTERN
-- ================================================================

CREATE OR REPLACE VIEW askwealth.v_cached_qa_pairs AS
WITH qa_pairs AS (
    SELECT 
        u.thread_id,
        u.message_id AS user_message_id,
        u.parts AS user_parts,
        u.annotations AS user_annotations,
        a.message_id AS assistant_message_id,
        a.parts AS assistant_parts,
        a.annotations AS assistant_annotations,
        
        -- Extract user question from parts
        (
            SELECT string_agg(
                CASE 
                    WHEN jsonb_typeof(part) = 'object' AND part ? 'text' THEN part->>'text'
                    WHEN jsonb_typeof(part) = 'string' THEN part#>>'{}'
                    ELSE part::text
                END, ' '
            )
            FROM jsonb_array_elements(u.parts) as part
        ) as user_question,
        
        -- Extract assistant answer from parts
        (
            SELECT string_agg(
                CASE 
                    WHEN jsonb_typeof(part) = 'object' AND part ? 'text' THEN part->>'text'
                    WHEN jsonb_typeof(part) = 'string' THEN part#>>'{}'
                    ELSE part::text
                END, ' '
            )
            FROM jsonb_array_elements(a.parts) as part
        ) as assistant_answer,
        
        -- Extract rephrased query from annotations (based on your pattern)
        COALESCE(
            a.annotations->'debug'->>'rephrase_question_result',
            a.annotations->>'rephrased_query',
            u.annotations->>'rephrased_query'
        ) as rephrased_query
        
    FROM askwealth.message u
    JOIN askwealth.message a ON u.thread_id = a.thread_id
        AND a.role = 'assistant'
        AND u.role = 'user'
        AND a.created_at = (
            SELECT MIN(created_at)
            FROM askwealth.message
            WHERE thread_id = u.thread_id
            AND role = 'assistant'
            AND created_at > u.created_at
        )
    WHERE a.annotations->'debug'->>'relevant_rephrase_question_result'->>'relevant' = 'true'
)
SELECT 
    thread_id,
    user_message_id,
    assistant_message_id,
    user_question,
    assistant_answer,
    rephrased_query,
    -- Check if already cached
    CASE WHEN qce.id IS NOT NULL THEN true ELSE false END as is_cached
FROM qa_pairs
LEFT JOIN askwealth.query_cache_embeddings qce ON qce.user_message_id = qa_pairs.user_message_id
WHERE user_question IS NOT NULL 
    AND assistant_answer IS NOT NULL
    AND rephrased_query IS NOT NULL
    AND length(trim(user_question)) > 10
    AND length(trim(assistant_answer)) > 20;

-- ================================================================
-- 4. CACHE LOOKUP FUNCTION
-- ================================================================

CREATE OR REPLACE FUNCTION askwealth.find_similar_cached_query(
    p_embedding extensions.vector,
    p_threshold decimal DEFAULT NULL
)
RETURNS TABLE (
    cache_id uuid,
    user_message_id uuid,
    assistant_message_id uuid,
    rephrased_query text,
    similarity_score decimal,
    cache_hits integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_threshold decimal;
    v_enabled text;
BEGIN
    -- Get configuration
    SELECT value INTO v_threshold FROM askwealth.query_cache_config WHERE key = 'similarity_threshold';
    SELECT value INTO v_enabled FROM askwealth.query_cache_config WHERE key = 'cache_enabled';
    
    -- Use provided threshold or default
    v_threshold := COALESCE(p_threshold, v_threshold::decimal, 0.85);
    
    -- Return empty if caching disabled
    IF v_enabled != 'true' THEN
        RETURN;
    END IF;
    
    -- Find most similar cached query above threshold
    RETURN QUERY
    SELECT 
        qce.id,
        qce.user_message_id,
        qce.assistant_message_id,
        qce.rephrased_query,
        (1 - (qce.rephrased_query_embedding <=> p_embedding))::decimal as similarity_score,
        qce.cache_hits
    FROM askwealth.query_cache_embeddings qce
    WHERE qce.rephrased_query_embedding IS NOT NULL
        AND (1 - (qce.rephrased_query_embedding <=> p_embedding)) >= v_threshold
    ORDER BY qce.rephrased_query_embedding <=> p_embedding ASC
    LIMIT 1;
END;
$$;

-- ================================================================
-- 5. CACHE MANAGEMENT FUNCTIONS
-- ================================================================

-- Add new cache entry
CREATE OR REPLACE FUNCTION askwealth.add_cache_entry(
    p_user_message_id uuid,
    p_assistant_message_id uuid,
    p_rephrased_query text,
    p_embedding extensions.vector
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_cache_id uuid;
BEGIN
    INSERT INTO askwealth.query_cache_embeddings (
        user_message_id,
        assistant_message_id,
        rephrased_query,
        rephrased_query_embedding
    ) VALUES (
        p_user_message_id,
        p_assistant_message_id,
        p_rephrased_query,
        p_embedding
    )
    ON CONFLICT (user_message_id, assistant_message_id) 
    DO UPDATE SET
        rephrased_query = EXCLUDED.rephrased_query,
        rephrased_query_embedding = EXCLUDED.rephrased_query_embedding
    RETURNING id INTO v_cache_id;
    
    RETURN v_cache_id;
END;
$$;

-- Record cache hit
CREATE OR REPLACE FUNCTION askwealth.record_cache_hit(p_cache_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE askwealth.query_cache_embeddings 
    SET 
        cache_hits = cache_hits + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = p_cache_id;
END;
$$;

-- Get cached answer details
CREATE OR REPLACE FUNCTION askwealth.get_cached_answer_details(p_cache_id uuid)
RETURNS TABLE (
    user_question text,
    assistant_answer text,
    user_parts jsonb,
    assistant_parts jsonb,
    user_annotations jsonb,
    assistant_annotations jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        -- Extract user question
        (
            SELECT string_agg(
                CASE 
                    WHEN jsonb_typeof(part) = 'object' AND part ? 'text' THEN part->>'text'
                    WHEN jsonb_typeof(part) = 'string' THEN part#>>'{}'
                    ELSE part::text
                END, ' '
            )
            FROM jsonb_array_elements(u.parts) as part
        ) as user_question,
        
        -- Extract assistant answer
        (
            SELECT string_agg(
                CASE 
                    WHEN jsonb_typeof(part) = 'object' AND part ? 'text' THEN part->>'text'
                    WHEN jsonb_typeof(part) = 'string' THEN part#>>'{}'
                    ELSE part::text
                END, ' '
            )
            FROM jsonb_array_elements(a.parts) as part
        ) as assistant_answer,
        
        u.parts as user_parts,
        a.parts as assistant_parts,
        u.annotations as user_annotations,
        a.annotations as assistant_annotations
        
    FROM askwealth.query_cache_embeddings qce
    JOIN askwealth.message u ON u.message_id = qce.user_message_id
    JOIN askwealth.message a ON a.message_id = qce.assistant_message_id
    WHERE qce.id = p_cache_id;
END;
$$;

-- ================================================================
-- 6. MAINTENANCE FUNCTIONS
-- ================================================================

-- Populate cache from existing Q&A pairs
CREATE OR REPLACE FUNCTION askwealth.populate_cache_from_existing()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer := 0;
    qa_record record;
BEGIN
    -- Note: This function adds entries without embeddings
    -- Embeddings need to be generated by the application
    
    FOR qa_record IN 
        SELECT DISTINCT
            user_message_id,
            assistant_message_id,
            rephrased_query
        FROM askwealth.v_cached_qa_pairs
        WHERE NOT is_cached
            AND rephrased_query IS NOT NULL
    LOOP
        INSERT INTO askwealth.query_cache_embeddings (
            user_message_id,
            assistant_message_id,
            rephrased_query
        ) VALUES (
            qa_record.user_message_id,
            qa_record.assistant_message_id,
            qa_record.rephrased_query
        )
        ON CONFLICT (user_message_id, assistant_message_id) DO NOTHING;
        
        v_count := v_count + 1;
    END LOOP;
    
    RETURN v_count;
END;
$$;

-- Clean up cache based on size limit
CREATE OR REPLACE FUNCTION askwealth.cleanup_cache()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_entries integer;
    v_current_count integer;
    v_deleted_count integer;
BEGIN
    -- Get max entries configuration
    SELECT value::integer INTO v_max_entries 
    FROM askwealth.query_cache_config 
    WHERE key = 'max_cache_entries';
    
    v_max_entries := COALESCE(v_max_entries, 5000);
    
    -- Get current count
    SELECT COUNT(*) INTO v_current_count FROM askwealth.query_cache_embeddings;
    
    -- Delete oldest entries if over limit
    IF v_current_count > v_max_entries THEN
        DELETE FROM askwealth.query_cache_embeddings 
        WHERE id IN (
            SELECT id 
            FROM askwealth.query_cache_embeddings 
            ORDER BY last_accessed NULLS FIRST, created_at ASC
            LIMIT (v_current_count - v_max_entries)
        );
        
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    ELSE
        v_deleted_count := 0;
    END IF;
    
    RETURN v_deleted_count;
END;
$$;