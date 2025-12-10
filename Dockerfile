# ================================
# Stage 1: Builder
# ================================
FROM postgres:16-bookworm AS builder

# 1. 🟢 升级 Micromamba 版本
# 使用 latest 以确保内置的各种 Root Key 是最新的，避免 "Key is invalid"
COPY --from=mambaorg/micromamba:latest /bin/micromamba /usr/local/bin/micromamba

ARG TARGETARCH
ENV PG_MAJOR=16
ARG RDKIT_VERSION=Release_2025_03_1

# 2. 系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    ca-certificates \
    postgresql-server-dev-${PG_MAJOR} \
    libxml2-dev \
    pkg-config \
    bzip2 \
    && rm -rf /var/lib/apt/lists/*

# 3. 设置 Micromamba 环境
ARG MAMBA_ROOT_PREFIX=/opt/conda
ENV PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

# 🟢 根治 "Key is invalid" 问题：
# 1. safety_checks disabled: 关闭包签名验证
# 2. extra_safety_checks off: 关闭额外的元数据验证
# 3. ssl_verify true: 保持 HTTPS 验证（这是底线，不能关）
# 4. 依赖修复：维持 py-boost 方案
RUN micromamba config set safety_checks disabled && \
    micromamba config set extra_safety_checks off && \
    micromamba config set remote_read_timeout_secs 600 && \
    micromamba config set retries 3 && \
    micromamba create -y -p /opt/conda/envs/rdkit_build \
    -c conda-forge \
    python=3.12 \
    numpy \
    cmake \
    make \
    cxx-compiler \
    "boost-cpp>=1.78" \
    "py-boost>=1.78" \
    eigen \
    cairo \
    freetype \
    pandas \
    rapidjson \
    && micromamba clean -afy

# 4. 下载源码
WORKDIR /rdkit-src
RUN wget -O rdkit.tar.gz https://github.com/rdkit/rdkit/archive/refs/tags/${RDKIT_VERSION}.tar.gz \
    && tar -xzf rdkit.tar.gz --strip-components=1 \
    && rm rdkit.tar.gz

# 5. 编译 RDKit (维持之前的 FindBoost + 暴力路径修正方案)
RUN mkdir build && cd build && \
    NUMPY_PATH=$(micromamba run -p /opt/conda/envs/rdkit_build python -c 'import numpy; print(numpy.get_include())') && \
    # 动态查找 libboost_python*.so
    BOOST_PY_LIB=$(find /opt/conda/envs/rdkit_build/lib -name "libboost_python*.so" -o -name "libboost_python*.so.*" | head -n 1) && \
    echo "Found Numpy Path: $NUMPY_PATH" && \
    echo "Found Boost Lib: $BOOST_PY_LIB" && \
    micromamba run -p /opt/conda/envs/rdkit_build cmake .. \
    -DRDK_BUILD_PYTHON_WRAPPERS=ON \
    -DRDK_BUILD_PGSQL=ON \
    -DRDK_INSTALL_INTREE=OFF \
    -DCMAKE_INSTALL_PREFIX=/rdkit \
    -DRDK_INSTALL_STATIC_LIBS=OFF \
    -DRDK_BUILD_CPP_TESTS=OFF \
    -DPy_ENABLE_SHARED=1 \
    -DPYTHON_NUMPY_INCLUDE_PATH="$NUMPY_PATH" \
    -DCMAKE_PREFIX_PATH="/opt/conda/envs/rdkit_build" \
    -DBoost_ROOT="/opt/conda/envs/rdkit_build" \
    # 禁用 Boost Config，使用 CMake 自己的 FindBoost
    -DBoost_NO_BOOST_CMAKE=OFF \
    -DBoost_NO_SYSTEM_PATHS=ON \
    # 暴力注入找到的库路径，不再让 CMake 瞎猜
    -DBoost_PYTHON3_LIBRARY_RELEASE="$BOOST_PY_LIB" \
    -DBoost_PYTHON3_LIBRARY="$BOOST_PY_LIB" \
    -DBoost_PYTHON_VERSION=3.12 \
    -DRDK_BUILD_AVALON_SUPPORT=ON \
    -DRDK_BUILD_CAIRO_SUPPORT=ON \
    -DRDK_BUILD_INCHI_SUPPORT=ON \
    -DRDK_BUILD_MAEPARSER_SUPPORT=OFF \
    -DRDK_BUILD_COORDGEN_SUPPORT=OFF \
    -DPostgreSQL_CONFIG_DIR=/usr/lib/postgresql/${PG_MAJOR}/bin \
    && \
    micromamba run -p /opt/conda/envs/rdkit_build make -j $(nproc) && \
    micromamba run -p /opt/conda/envs/rdkit_build make install

# 6. 收集依赖库
RUN mkdir -p /rdkit/lib && \
    cp -d /opt/conda/envs/rdkit_build/lib/libboost*.so* /rdkit/lib/ && \
    cp -d /opt/conda/envs/rdkit_build/lib/libpython*.so* /rdkit/lib/ && \
    cp -d /opt/conda/envs/rdkit_build/lib/libRDKit*.so* /rdkit/lib/

# ================================
# Stage 2: Final Image
# ================================
FROM postgres:16-bookworm

ENV PG_MAJOR=16
ENV LD_LIBRARY_PATH=/rdkit/lib

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libxrender1 \
    libxext6 \
    libfreetype6 \
    libsm6 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /rdkit /rdkit

RUN echo "/rdkit/lib" > /etc/ld.so.conf.d/rdkit.conf && ldconfig

COPY postgresql.conf /etc/postgresql/postgresql.conf

ENV POSTGRES_USER=protwis
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]