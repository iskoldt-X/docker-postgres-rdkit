# ================================
# Stage 1: Builder (Native Debian)
# ================================
FROM postgres:16-bookworm AS builder
ARG RDKIT_VERSION=Release_2025_03_1
ENV PG_MAJOR=16

# 1. 安装构建工具和依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
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

# 2. 下载源码
WORKDIR /rdkit-src
RUN git clone --depth 1 --branch ${RDKIT_VERSION} https://github.com/rdkit/rdkit.git . \
    && rm -rf .git

# 3. 编译 RDKit
# 【关键修正点】
# 1. -DCMAKE_INSTALL_PREFIX=/rdkit : 确保 make install 把文件放到 /rdkit，这样 Stage 2 才能复制
# 2. -DPostgreSQL_... : 解决找不到 postgres.h 的问题
# 3. -std=gnu89 : 解决旧代码在新 GCC 下的编译问题
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

# 安装运行时依赖
# libfreetype6 是必须的，否则 rdkit.so 加载时会报 symbol lookup error
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

# 1. 复制 RDKit 核心库 (现在 builder 里有这个文件夹了！)
COPY --from=builder /rdkit /rdkit

# 2. 复制 Postgres 扩展
# 原理：RDKit 扩展虽然安装了，但通常是根据 pg_config 安装到系统 Postgres 目录的
# 所以我们要从系统目录里把它们捞出来
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR}/lib/rdkit.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=builder /usr/share/postgresql/${PG_MAJOR}/extension/rdkit* /usr/share/postgresql/${PG_MAJOR}/extension/

# 3. 链接库
# 告诉系统去 /rdkit/lib 下面找 libRDKit*.so
RUN echo "/rdkit/lib" > /etc/ld.so.conf.d/rdkit.conf && ldconfig

# 4. 原始配置
ENV POSTGRES_USER=protwis
CMD ["postgres"]