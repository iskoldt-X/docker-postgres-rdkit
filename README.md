# PostgreSQL Docker Image with RDKit Cartridge

[![Build Multi-Arch Docker Image](https://github.com/iskoldt-X/docker-postgres-rdkit/actions/workflows/build_multi_arch.yml/badge.svg)](https://github.com/iskoldt-X/docker-postgres-rdkit/actions/workflows/build_multi_arch.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/iskoldt/postgres16-rdkit?logo=docker&logoColor=white)](https://hub.docker.com/r/iskoldt/postgres16-rdkit)
[![Docker Image Size (latest)](https://img.shields.io/docker/image-size/iskoldt/postgres16-rdkit/latest?logo=docker&logoColor=white)](https://hub.docker.com/r/iskoldt/postgres16-rdkit)


A PostgreSQL 16 Docker image with the RDKit cartridge pre-installed and optimized for chemical informatics workloads.

This image inherits from the [official postgres image](https://hub.docker.com/_/postgres/), and therefore has all the same environment variables for configuration, and can be extended by adding entrypoint scripts to the `/docker-entrypoint-initdb.d` directory to be run on first launch.

## Features

- **Multi-architecture support**: Built for both AMD64 and ARM64 platforms
- **Optimized configuration**: Pre-configured `postgresql.conf` with RDKit-optimized settings
- **Automated builds**: Images are automatically built and published via GitHub Actions
- **Modern Dockerfile**: Multi-stage build for smaller image size and faster builds
- **PostgreSQL 16**: Based on the latest PostgreSQL 16 (bookworm) image
- **RDKit 2025.03.1**: The latest release compatible with Debian 12 (Bookworm) and its system Boost libraries (v1.74), ensuring maximum stability without experimental dependencies.

## Quick Start

Pull and run the image:

```bash
docker run -d \
  --name postgres-rdkit \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=mydb \
  -p 5432:5432 \
  iskoldt/postgres16-rdkit:latest
```

Or use Docker Compose:

```yaml
services:
  db:
    image: iskoldt/postgres16-rdkit:latest
    restart: always
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: mydb
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets:
      - postgres_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

volumes:
  postgres_data:

secrets:
  postgres_password:
    external: true
```

## Running

### Basic Usage

Start PostgreSQL with RDKit support:

```bash
docker run -d \
  --name postgres-rdkit \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  -p 5432:5432 \
  iskoldt/postgres16-rdkit:latest
```

### Security Best Practices

**Important**: Never hardcode passwords in command lines or Docker Compose files. Use one of these secure methods:

1. **Docker Secrets** (recommended for Docker Swarm or Docker Compose):
   ```bash
   echo "your-secure-password" | docker secret create postgres_password -
   ```

2. **Environment Files**:
   ```bash
   docker run -d \
     --name postgres-rdkit \
     --env-file .env \
     -p 5432:5432 \
     iskoldt/postgres16-rdkit:latest
   ```
   Where `.env` contains:
   ```
   POSTGRES_PASSWORD=your-secure-password
   ```

3. **Environment Variables** (for development only):
   ```bash
   export POSTGRES_PASSWORD="your-secure-password"
   docker run -d \
     --name postgres-rdkit \
     -e POSTGRES_PASSWORD \
     -p 5432:5432 \
     iskoldt/postgres16-rdkit:latest
   ```

### Docker Compose Example

```yaml
services:
  db:
    image: iskoldt/postgres16-rdkit:latest
    restart: always
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: mydb
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets:
      - postgres_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:

secrets:
  postgres_password:
    file: ./secrets/postgres_password.txt
```

This image exposes port 5432 (the postgres port), so standard container linking will make it automatically available to the linked containers.

## Environment Variables

- `POSTGRES_PASSWORD`: Superuser password for PostgreSQL (use `POSTGRES_PASSWORD_FILE` for secrets instead).
- `POSTGRES_USER`: Superuser username (default `postgres`).
- `POSTGRES_DB`: Default database that is created when the image is first started.
- `PGDATA`: Location for the database files (default `/var/lib/postgresql/data`).

See the [official postgres image](https://hub.docker.com/_/postgres/) for more details.

## Building

### Automated Builds via GitHub Actions

Images are automatically built and published to Docker Hub via GitHub Actions when:
- Code is pushed to the `main` branch
- The workflow is manually triggered

The build process:
- Builds multi-architecture images (AMD64 and ARM64)
- Tags images with both `latest` and date-based versions (YYYY.MM.DD format)
- Publishes to Docker Hub as `iskoldt/postgres16-rdkit`

See `.github/workflows/build_multi_arch.yml` for the build configuration.

### Manual Building

To build the image manually:

```bash
docker build -t iskoldt/postgres16-rdkit:latest .
```

The Dockerfile uses a multi-stage build:
- **Stage 1 (Builder)**: Compiles RDKit from source on `postgres:16-bookworm`
- **Stage 2 (Final)**: Creates the final image with only runtime dependencies

Build arguments:
- `RDKIT_VERSION`: RDKit version to build (default: `Release_2025_03_1`)

Example with custom RDKit version:

```bash
docker build \
  --build-arg RDKIT_VERSION=Release_2024_09_2 \
  -t iskoldt/postgres16-rdkit:custom .
```

## Configuration

### PostgreSQL Configuration

The image includes a pre-configured `postgresql.conf` optimized for RDKit workloads. Key settings include:

> **Note**: The default configuration is tuned for a high-performance workstation (e.g., Apple M2 Max, Oracle Cloud ARM) with ~10-12GB RAM available. If running on a smaller instance (e.g., 2GB RAM), you MUST override `shared_buffers` and `work_mem` via command line flags or a custom config file to avoid OOM crashes.

#### Memory Settings
- `shared_buffers = 2560MB`: 25% of 10GB container RAM
- `effective_cache_size = 7GB`: ~70% of 10GB container RAM
- `work_mem = 64MB`: Per-query memory limit
- `maintenance_work_mem = 512MB`: For vacuum and index creation

#### Storage/IO Optimizations
- `random_page_cost = 1.1`: Optimized for NVMe SSD
- `effective_io_concurrency = 200`: High concurrency for NVMe
- `min_wal_size = 1GB`: Reduce checkpoint frequency
- `max_wal_size = 4GB`: Limit WAL disk usage
- `checkpoint_completion_target = 0.9`: Spread checkpoint I/O load

#### Parallelism
- `max_worker_processes = 10`: Allow background workers + parallel queries
- `max_parallel_workers = 8`: Utilize performance cores
- `max_parallel_workers_per_gather = 4`: Limit parallel workers per query

#### Connections & Safety
- `max_connections = 200`: Support expected concurrent users
- `synchronous_commit = on`: Ensure data durability
- `full_page_writes = on`: Protect against partial page writes
- `listen_addresses = '*'`: Listen on all interfaces

### Customizing Configuration

To use your own `postgresql.conf`:

```bash
docker run -d \
  --name postgres-rdkit \
  -v /path/to/custom/postgresql.conf:/etc/postgresql/postgresql.conf \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  iskoldt/postgres16-rdkit:latest \
  postgres -c config_file=/etc/postgresql/postgresql.conf
```

## Performance Optimization

The included `postgresql.conf` is already optimized for RDKit workloads. However, if you need to further optimize for specific use cases:

### For Building the Database (High-Volume Inserts)

If you're doing bulk inserts and building indexes, you can temporarily adjust these settings (at the cost of data safety):

```sql
-- WARNING: These settings reduce data safety
ALTER SYSTEM SET synchronous_commit = 'off';
ALTER SYSTEM SET full_page_writes = 'off';
SELECT pg_reload_conf();
```

**Warning**: 
- `synchronous_commit = off`: Speeds normal operation but increases the chance of losing commits if PostgreSQL crashes. Commits will be reported as executed even if not stored and flushed to durable storage.
- `full_page_writes = off`: Speeds normal operation but might lead to unrecoverable or silent data corruption after a system failure.

**Recommendation**: Only use these settings during initial data loading. To revert to production safety:

```sql
-- Revert to safe production defaults
ALTER SYSTEM RESET synchronous_commit;
ALTER SYSTEM RESET full_page_writes;
SELECT pg_reload_conf();
```

### For Queries (Structural Searches)

The default configuration already includes optimized memory settings:
- `shared_buffers = 2560MB`: PostgreSQL's dedicated RAM
- `work_mem = 64MB`: Maximum RAM per query operation before using disk

These settings increase the RAM requirements for PostgreSQL. Ensure your container has sufficient memory allocated.

Source: [RDKit Cartridge Configuration](https://www.rdkit.org/docs/Cartridge.html#configuration)

For more information, see the [RDKit PostgreSQL Cartridge documentation](https://www.rdkit.org/docs/Cartridge.html).

## Image Details

- **Base Image**: `postgres:16-bookworm`
- **RDKit Version**: Release_2025_03_1
- **PostgreSQL Version**: 16
- **Architectures**: linux/amd64, linux/arm64
- **Image Size**: ~813 MB

## License

See [LICENSE](LICENSE) file for details.
