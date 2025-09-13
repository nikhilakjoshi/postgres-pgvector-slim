# PostgreSQL Docker Setup

This Docker Compose setup creates a PostgreSQL database with the following configuration:

## Database Configuration

- **Database Name**: `askwealth`
- **Port**: `5432`
- **Admin User**: `postgres` (password: `postgres`)

## Application Users

- **Read-Write User**: `askwealth_rw_dev` (password: `hello`)
- **Admin User**: `askwealth_admin_dev` (password: `hello`)

## Application Role

- **Role**: `citi_pg_app_owner` - All application operations should run under this role

Both application users are granted the `citi_pg_app_owner` role and have it set as their default role.

## Usage

### Start the database

```bash
docker-compose up -d
```

### Stop the database

```bash
docker-compose down
```

### Connect to the database

```bash
# As the read-write user
docker-compose exec postgres psql -U askwealth_rw_dev -d askwealth

# As the admin user
docker-compose exec postgres psql -U askwealth_admin_dev -d askwealth

# As the default postgres user
docker-compose exec postgres psql -U postgres -d askwealth
```

### Check database status

```bash
docker-compose ps
```

### View logs

```bash
docker-compose logs postgres
```

## File Structure

- `docker-compose.yml` - Main compose configuration
- `init-db/01-init-users.sql` - Database initialization script
- `.env` - Environment variables (optional, for reference)

## Data Persistence

Database data is persisted in a Docker volume named `postgres_data`. To completely reset the database:

```bash
docker-compose down -v
docker-compose up -d
```

## Health Check

The PostgreSQL container includes a health check that verifies the database is ready to accept connections.
