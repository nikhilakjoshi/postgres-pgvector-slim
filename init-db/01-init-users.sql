-- Initialize database with required users and roles
-- This script runs during container initialization

-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create the askwealth schema
CREATE SCHEMA IF NOT EXISTS askwealth;

-- Create the application role
CREATE ROLE citi_pg_app_owner;

-- Grant necessary privileges to the application role
GRANT CONNECT ON DATABASE "askwealth-dev" TO citi_pg_app_owner;
GRANT CREATE ON DATABASE "askwealth-dev" TO citi_pg_app_owner;
GRANT USAGE ON SCHEMA askwealth TO citi_pg_app_owner;
GRANT CREATE ON SCHEMA askwealth TO citi_pg_app_owner;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA askwealth TO citi_pg_app_owner;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA askwealth TO citi_pg_app_owner;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA askwealth TO citi_pg_app_owner;

-- Ensure future objects inherit the privileges
ALTER DEFAULT PRIVILEGES IN SCHEMA askwealth GRANT ALL PRIVILEGES ON TABLES TO citi_pg_app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA askwealth GRANT ALL PRIVILEGES ON SEQUENCES TO citi_pg_app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA askwealth GRANT ALL PRIVILEGES ON FUNCTIONS TO citi_pg_app_owner;

-- Create the read-write user
CREATE USER askwealth_rw_dev WITH PASSWORD 'hello';

-- Create the admin user
CREATE USER askwealth_admin_dev WITH PASSWORD 'hello';

-- Grant the application role to both users
GRANT citi_pg_app_owner TO askwealth_rw_dev;
GRANT citi_pg_app_owner TO askwealth_admin_dev;

-- Grant additional admin privileges to the admin user
ALTER USER askwealth_admin_dev CREATEDB;
ALTER USER askwealth_admin_dev CREATEROLE;

-- Set default role and search path for users
ALTER USER askwealth_rw_dev SET ROLE citi_pg_app_owner;
ALTER USER askwealth_rw_dev SET search_path TO askwealth;
ALTER USER askwealth_admin_dev SET ROLE citi_pg_app_owner;
ALTER USER askwealth_admin_dev SET search_path TO askwealth;

-- Display created users and roles for verification
\echo 'Database initialization completed!'
\echo 'Enabled extensions:'
\echo '  - pgvector (for vector similarity search)'
\echo 'Created schema:'
\echo '  - askwealth (custom application schema)'
\echo 'Created users:'
\echo '  - askwealth_rw_dev (with role citi_pg_app_owner)'
\echo '  - askwealth_admin_dev (with role citi_pg_app_owner and admin privileges)'
\echo 'Created role:'
\echo '  - citi_pg_app_owner (application role with full database privileges)'