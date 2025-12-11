# ================================
# Stage 1: Builder (Native Debian)
# ================================
FROM postgres:16-bookworm AS builder
ENV PG_MAJOR=16

# [DYNAMIC FETCH] 1. Install build tools (Added 'curl' to fetch API)
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

# [DYNAMIC FETCH] 2. Download source code (The Magic Step)
WORKDIR /rdkit-src

# Define cache bust parameter. Docker may reuse previous layers if not passed this parameter.
# Pass method: docker build --build-arg CACHEBUST=$(date +%s) ...
ARG CACHEBUST=1

RUN echo "🔍 Fetching latest RDKit release tag from GitHub..." && \
    export LATEST_TAG=$(curl -sL https://api.github.com/repos/rdkit/rdkit/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') && \
    echo "🔥 Detected Latest RDKit Release: ${LATEST_TAG}" && \
    # Record version info file for debugging/tracking
    echo "${LATEST_TAG}" > /rdkit_version.txt && \
    git clone --depth 1 --branch ${LATEST_TAG} https://github.com/rdkit/rdkit.git . && \
    rm -rf .git

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

# Copy RDKit core library
COPY --from=builder /rdkit /rdkit

# [DYNAMIC FETCH] Copy version info file for debugging/tracking
COPY --from=builder /rdkit_version.txt /etc/rdkit_version.txt

# Copy Postgres extension
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR}/lib/rdkit.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=builder /usr/share/postgresql/${PG_MAJOR}/extension/rdkit* /usr/share/postgresql/${PG_MAJOR}/extension/

# Link library
RUN echo "/rdkit/lib" > /etc/ld.so.conf.d/rdkit.conf && ldconfig

# Original configuration
ENV POSTGRES_USER=protwis

# Custom Configuration
COPY postgresql.conf /etc/postgresql/postgresql.conf
RUN chown postgres:postgres /etc/postgresql/postgresql.conf

# Show the version when container builds (optional, just for logs)
RUN echo "✅ Build complete. RDKit Version: $(cat /etc/rdkit_version.txt)"

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]