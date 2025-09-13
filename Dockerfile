# Use PostgreSQL 15 Alpine as base image
FROM postgres:15-alpine

# Install dependencies needed to build pgvector
RUN apk add --no-cache \
    build-base \
    gcc \
    musl-dev \
    git \
    postgresql-dev \
    make

# Multi-stage build for minimal image size
# Stage 1: Build pgvector only
FROM alpine:3.18 AS builder

# Install PostgreSQL and build dependencies
RUN apk add --no-cache \
    postgresql15-dev \
    build-base \
    gcc \
    musl-dev \
    git \
    make

# Clone and build pgvector
RUN git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git /tmp/pgvector && \
    cd /tmp/pgvector && \
    make clean && \
    make vector.so PG_CONFIG=/usr/lib/postgresql15/bin/pg_config && \
    cp vector.so /tmp/ && \
    cp sql/vector.sql /tmp/vector--0.5.1.sql && \
    cp vector.control /tmp/

# Stage 2: Minimal runtime image based on original postgres alpine
FROM postgres:15-alpine

# Remove unnecessary packages to reduce size
RUN apk del --no-cache \
    postgresql15-doc \
    readline-dev \
    libedit-dev

# Copy only the essential pgvector files from builder
COPY --from=builder /tmp/vector.so /usr/local/lib/postgresql/
COPY --from=builder /tmp/vector--0.5.1.sql /usr/local/share/postgresql/extension/
COPY --from=builder /tmp/vector.control /usr/local/share/postgresql/extension/

# Copy initialization scripts
COPY init-db/ /docker-entrypoint-initdb.d/

# Create initialization script to enable pgvector automatically  
RUN echo "CREATE EXTENSION IF NOT EXISTS vector;" > /docker-entrypoint-initdb.d/00-enable-vector.sql

# Expose PostgreSQL port
EXPOSE 5432

# Copy initialization scripts if any
COPY init-db/ /docker-entrypoint-initdb.d/

# Expose PostgreSQL port
EXPOSE 5432

# Use the default PostgreSQL entrypoint
CMD ["postgres"]