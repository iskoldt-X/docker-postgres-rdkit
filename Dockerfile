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
# Static version clone
RUN git clone --depth 1 --branch ${RDKIT_VERSION} https://github.com/rdkit/rdkit.git . \
    && rm -rf .git

# 3. Compile RDKit
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

# 4. Artifact Staging
# Prepare a single directory /dist requiring only one COPY in final stage
WORKDIR /dist
RUN mkdir -p /dist/rdkit \
    /dist/usr/lib/postgresql/${PG_MAJOR}/lib \
    /dist/usr/share/postgresql/${PG_MAJOR}/extension

# Move RDKit core library
RUN cp -r /rdkit/* /dist/rdkit/

# Move Postgres extension files
RUN cp /usr/lib/postgresql/${PG_MAJOR}/lib/rdkit.so /dist/usr/lib/postgresql/${PG_MAJOR}/lib/
RUN cp /usr/share/postgresql/${PG_MAJOR}/extension/rdkit* /dist/usr/share/postgresql/${PG_MAJOR}/extension/

# ================================
# Stage 2: Final Image
# ================================
FROM postgres:16-bookworm
ENV PG_MAJOR=16

# 1. Copy all artifacts from builder in a single layer
COPY --from=builder /dist /

# 2. Install runtime dependencies & Configure System
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
    && echo "/rdkit/lib" > /etc/ld.so.conf.d/rdkit.conf \
    && ldconfig \
    && rm -rf /var/lib/apt/lists/*

# Original configuration
ENV POSTGRES_USER=protwis

# Custom Configuration (Kept at the end to preserve cache during config tuning)
COPY --chown=postgres:postgres postgresql.conf /etc/postgresql/postgresql.conf

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]