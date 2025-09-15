# AskWealth Data Model Documentation

## Overview

The AskWealth application uses a PostgreSQL database with the pgvector extension for vector similarity search and embeddings. The database is designed to handle knowledge management, document processing, and AI-powered Q&A functionality.

## Database Architecture

### Schemas

- **askwealth**: Main application schema containing all business logic tables
- **extensions**: Contains database extensions and utility functions
- **Database**: `askwealth-dev`

### Extensions

- **pgvector**: Enables vector similarity search for AI embeddings and semantic search

## Core Data Model

The data model consists of several interconnected entities that support document management, AI processing, and user interactions:

### 1. Document Management

#### `askwealth.document`

Primary entity for storing documents and their metadata.

```sql
CREATE TABLE askwealth.document (
    document_id uuid NOT NULL,
    record_id uuid NOT NULL,
    metadata jsonb NULL,
    status askwealth."document_status" NOT NULL,
    created_at timestamp NOT NULL,
    updated_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    updated_by varchar(50) NOT NULL,
    CONSTRAINT document_pkey PRIMARY KEY (document_id),
    CONSTRAINT uq_document_record_id UNIQUE (record_id),
    CONSTRAINT document_record_id_fkey FOREIGN KEY (record_id) REFERENCES askwealth.record(record_id) ON DELETE CASCADE
);
```

**Key Features:**

- `document_id`: Unique identifier for each document
- `record_id`: Links to the record table for hierarchical organization
- `metadata`: Flexible JSON storage for document properties
- `status`: Enum field tracking document processing status
- Audit fields: `created_at`, `updated_at`, `created_by`, `updated_by`

#### `askwealth.chunk`

Stores document chunks for processing and vector embeddings.

```sql
CREATE TABLE askwealth.chunk (
    chunk_id uuid NOT NULL,
    document_id uuid NOT NULL,
    chunk_index int4 NOT NULL,
    text text NOT NULL,
    metadata jsonb NULL,
    content_hash varchar(255) NOT NULL,
    created_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    embedding extensions.vector NOT NULL,
    CONSTRAINT chunk_pkey PRIMARY KEY (chunk_id),
    CONSTRAINT chunk_document_id_fkey FOREIGN KEY (document_id) REFERENCES askwealth."document"(document_id) ON DELETE CASCADE
);
```

**Key Features:**

- `chunk_id`: Unique identifier for each chunk
- `document_id`: Links to parent document
- `chunk_index`: Ordering of chunks within a document
- `text`: The actual text content of the chunk
- `content_hash`: Hash for deduplication and integrity
- `embedding`: Vector representation for similarity search (pgvector type)

### 2. Record Hierarchy

#### `askwealth.record`

Central entity for organizing and categorizing content.

```sql
CREATE TABLE askwealth.record (
    record_id uuid NOT NULL,
    "source" varchar(255) NOT NULL,
    source_id varchar(225) NOT NULL,
    "version" int4 NOT NULL,
    reason askwealth."record_reason" NOT NULL,
    event_id uuid NOT NULL,
    record jsonb NOT NULL,
    created_at timestamp NOT NULL,
    updated_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    updated_by varchar(50) NOT NULL,
    status askwealth."record_status" NOT NULL,
    CONSTRAINT record_pkey PRIMARY KEY (record_id),
    CONSTRAINT uix_source_version UNIQUE (source, source_id, version),
    CONSTRAINT record_event_id_fkey FOREIGN KEY (event_id) REFERENCES askwealth."event"(event_id) ON DELETE CASCADE
);
```

**Key Features:**

- `record_id`: Unique identifier
- `source` & `source_id`: External system identification
- `version`: Version control for record updates
- `reason`: Enum indicating why the record was created/updated
- `event_id`: Links to triggering event
- `record`: Flexible JSON storage for record data

### 3. Event Tracking

#### `askwealth.event`

Tracks system events and operations.

```sql
CREATE TABLE askwealth."event" (
    event_id uuid NOT NULL,
    kind askwealth."event_kind" NOT NULL,
    event_input jsonb NOT NULL,
    event_output jsonb NULL,
    created_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    started_at timestamp NULL,
    finished_at timestamp NULL,
    status askwealth."event_status" NOT NULL,
    CONSTRAINT event_pkey PRIMARY KEY (event_id)
);
```

**Key Features:**

- `event_id`: Unique identifier
- `kind`: Type of event (enum)
- `event_input` & `event_output`: JSON payloads for event data
- Timing fields: `created_at`, `started_at`, `finished_at`
- `status`: Current event status

### 4. Communication & Interaction

#### `askwealth.thread`

Manages conversation threads for user interactions.

```sql
CREATE TABLE askwealth.thread (
    thread_id uuid NOT NULL,
    title varchar(255) NOT NULL,
    created_at timestamp NOT NULL,
    updated_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    updated_by varchar(50) NOT NULL,
    CONSTRAINT thread_pkey PRIMARY KEY (thread_id)
);
```

#### `askwealth.message`

Stores individual messages within threads.

```sql
CREATE TABLE askwealth.message (
    message_id uuid NOT NULL,
    "role" varchar(50) NOT NULL,
    parts jsonb NOT NULL,
    created_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    annotations jsonb NULL,
    CONSTRAINT message_pkey PRIMARY KEY (message_id),
    CONSTRAINT message_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES askwealth.thread(thread_id) ON DELETE CASCADE
);
```

**Key Features:**

- `message_id`: Unique identifier
- `role`: Message sender role (user, assistant, system, etc.)
- `parts`: JSON array of message components
- `annotations`: Additional metadata

### 5. User Feedback & Content Management

#### `askwealth.feedback`

Captures user feedback on system responses.

```sql
CREATE TABLE askwealth.feedback (
    feedback_id uuid NOT NULL,
    kind varchar(50) NOT NULL,
    feedback_input jsonb NOT NULL,
    feedback_output jsonb NULL,
    message_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    created_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    CONSTRAINT feedback_pkey PRIMARY KEY (feedback_id)
);
```

#### `askwealth.pin`

Manages pinned or bookmarked content.

```sql
CREATE TABLE askwealth.pin (
    pin_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    "content" jsonb NULL,
    created_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    updated_at timestamp NOT NULL,
    updated_by varchar(50) NOT NULL,
    CONSTRAINT pin_pkey PRIMARY KEY (pin_id)
);
```

### 6. Configuration Management

#### `askwealth.config`

Stores application configuration parameters.

```sql
CREATE TABLE askwealth.config (
    "key" varchar(1000) NOT NULL,
    value jsonb NULL,
    created_at timestamp NOT NULL,
    created_by varchar(50) NOT NULL,
    updated_at timestamp NOT NULL,
    updated_by varchar(50) NOT NULL,
    CONSTRAINT config_pkey PRIMARY KEY (key)
);
```

#### `askwealth.alembic_version`

Database migration version tracking (Alembic ORM).

```sql
CREATE TABLE askwealth.alembic_version (
    version_num varchar(32) NOT NULL,
    CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
);
```

## Entity Relationships

### Primary Relationships

1. **Record → Document**: One-to-one relationship

   - Each record can have one associated document
   - Documents cannot exist without a record

2. **Document → Chunk**: One-to-many relationship

   - Each document can have multiple chunks
   - Chunks belong to exactly one document

3. **Event → Record**: One-to-many relationship

   - Each event can trigger multiple records
   - Each record is associated with one event

4. **Thread → Message**: One-to-many relationship

   - Each thread contains multiple messages
   - Messages belong to exactly one thread

5. **Thread → Pin**: One-to-many relationship
   - Each thread can have multiple pins
   - Pins belong to exactly one thread

### Data Flow

```
Event → Record → Document → Chunk (with embeddings)
                ↓
Thread → Message ← Feedback
        ↓
       Pin
```

## Key Design Patterns

### 1. Audit Trail

All major entities include audit fields:

- `created_at` / `updated_at`: Timestamps
- `created_by` / `updated_by`: User identification

### 2. Flexible Storage

JSON/JSONB fields enable flexible schema evolution:

- `metadata` fields for extensible properties
- `record` field for varying data structures
- `parts` and `annotations` for complex message content

### 3. Vector Search

The `embedding` field in chunks enables:

- Semantic similarity search
- RAG (Retrieval-Augmented Generation) functionality
- Content recommendation

### 4. Status Tracking

Enum fields track processing states:

- `document_status`: Document processing pipeline
- `record_status`: Record validation states
- `event_status`: Event lifecycle management

### 5. Versioning

- Records support versioning via `version` field
- Alembic handles database schema versioning

## Technical Considerations

### Performance

- UUIDs used for all primary keys (globally unique, distributed-friendly)
- Indexes on foreign keys for join performance
- Vector indexes for embedding similarity search

### Scalability

- JSON fields allow schema flexibility without migrations
- Event-driven architecture supports asynchronous processing
- Chunk-based document storage enables parallel processing

### Data Integrity

- Foreign key constraints ensure referential integrity
- Unique constraints prevent data duplication
- Cascade deletes maintain consistency

## Usage Patterns

### Document Processing Pipeline

1. Event triggers document ingestion
2. Record created with source information
3. Document entity created and linked to record
4. Document content chunked and stored
5. Embeddings generated for each chunk
6. Document status updated through processing stages

### User Interaction Flow

1. User creates thread
2. Messages exchanged within thread
3. System generates responses using chunk embeddings
4. User provides feedback on responses
5. Important content can be pinned for reference

This data model supports a sophisticated AI-powered knowledge management system with robust tracking, flexible content storage, and semantic search capabilities.
