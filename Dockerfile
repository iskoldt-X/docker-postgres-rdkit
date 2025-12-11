# ================================
# Stage 1: Builder (Native Debian)
# ================================
FROM postgres:16-bookworm AS builder
ARG RDKIT_VERSION=Release_2025_03_1
ENV PG_MAJOR=16

# 1. Install build tools and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    curl \
    ca-certificates \
    postgresql-server-dev-${PG_MAJOR} \
    libxml2-dev \
    libboost-all-dev \
    libpython3-dev \
    python3-numpy \
    libsqlite3-dev \
    zlib1g-dev \
    libfreetype6-dev \
    libeigen3-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. Download source code
WORKDIR /rdkit-src
# Dynamic fetch commented out for stability
# RUN echo "🔍 Fetching latest RDKit release tag from GitHub..." && \
#     export LATEST_TAG=$(curl -sL https://api.github.com/repos/rdkit/rdkit/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') && \
#     echo "🔥 Detected Latest RDKit Release: ${LATEST_TAG}" && \
#     # Record version info file for debugging/tracking
#     echo "${LATEST_TAG}" > /rdkit_version.txt && \
#     git clone --depth 1 --branch ${LATEST_TAG} https://github.com/rdkit/rdkit.git . && \
#     rm -rf .git

# Static version clone
RUN git clone --depth 1 --branch ${RDKIT_VERSION} https://github.com/rdkit/rdkit.git . \
    && rm -rf .git

# 3. Compile RDKit
# Key fix points:
# 1. -DCMAKE_INSTALL_PREFIX=/rdkit : Ensure make install puts files in /rdkit
# 2. -DPostgreSQL_... : Resolve missing postgres.h issue
# 3. -std=gnu89 : Resolve old code compilation issues with new GCC
RUN mkdir build && cd build && \
    cmake .. \
    -DCMAKE_INSTALL_PREFIX=/rdkit \
    -DCMAKE_C_FLAGS="-Wno-error=implicit-function-declaration -std=gnu89" \
    -DRDK_BUILD_PYTHON_WRAPPERS=ON \
    -DRDK_BUILD_PGSQL=ON \
    -DRDK_INSTALL_INTREE=OFF \
    -DRDK_INSTALL_STATIC_LIBS=OFF \
    -DRDK_BUILD_CPP_TESTS=OFF \
    -DPy_ENABLE_SHARED=1 \
    -DRDK_BUILD_AVALON_SUPPORT=ON \
    -DRDK_BUILD_CAIRO_SUPPORT=OFF \
    -DRDK_BUILD_INCHI_SUPPORT=ON \
    -DRDK_BUILD_FREETYPE_SUPPORT=ON \
    -DPostgreSQL_CONFIG_DIR=/usr/lib/postgresql/${PG_MAJOR}/bin \
    -DPostgreSQL_INCLUDE_DIR=/usr/include/postgresql \
    -DPostgreSQL_TYPE_INCLUDE_DIR=/usr/include/postgresql/${PG_MAJOR}/server \
    && \
    make -j $(nproc) && \
    make install

# ================================
# Stage 2: Final Image
# ================================
FROM postgres:16-bookworm
ENV PG_MAJOR=16

# Install runtime dependencies
# libfreetype6 is required, otherwise rdkit.so will report symbol lookup error
RUN apt-get update && apt-get install -y --no-install-recommends \
    libboost-serialization1.74.0 \
    libboost-system1.74.0 \
    libboost-iostreams1.74.0 \
    libboost-python1.74.0 \
    libpython3.11 \
    python3-numpy \
    libxml2 \
    libfreetype6 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy RDKit core library (now available in builder)
COPY --from=builder /rdkit /rdkit

# Copy Postgres extension
# Principle: RDKit extension is installed, but usually according to pg_config to system Postgres directory
# So we need to take them out from system directory
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR}/lib/rdkit.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=builder /usr/share/postgresql/${PG_MAJOR}/extension/rdkit* /usr/share/postgresql/${PG_MAJOR}/extension/

# Link library
# Tell system to look for libRDKit*.so in /rdkit/lib
RUN echo "/rdkit/lib" > /etc/ld.so.conf.d/rdkit.conf && ldconfig

# Original configuration
ENV POSTGRES_USER=protwis

# Custom Configuration
COPY postgresql.conf /etc/postgresql/postgresql.conf
RUN chown postgres:postgres /etc/postgresql/postgresql.conf

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]