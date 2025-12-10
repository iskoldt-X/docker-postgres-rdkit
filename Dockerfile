# ================================
# Stage 1: Builder
# ================================
FROM postgres:16-bookworm AS builder

# 启用 BuildKit 架构参数
ARG TARGETARCH
# 定义 RDKit 版本
ARG RDKIT_VERSION=Release_2025_03_1
ENV PG_MAJOR=16

# 1. 安装系统基础工具
# 注意：必须安装 curl, bzip2, ca-certificates 以支持 Micromamba 安装脚本
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    curl \
    bzip2 \
    ca-certificates \
    postgresql-server-dev-${PG_MAJOR} \
    libxml2-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 2. 正确安装 Micromamba (Fixing the "Key is invalid" issue)
# 采用 Gemini 建议的 "Installer Pattern" 而非 "Sidecar Copy"
# 这样能确保 TUF Keys 和信任库被正确初始化。
ARG MAMBA_ROOT_PREFIX=/opt/conda
ENV PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

RUN curl -Ls https://micro.mamba.pm/api/micromamba/linux-${TARGETARCH}/latest | tar -xj -C /usr/local/bin/ --strip-components=1 bin/micromamba \
    && micromamba shell init -s bash -p $MAMBA_ROOT_PREFIX \
    && mkdir -p $MAMBA_ROOT_PREFIX/conda-meta

# 3. 创建构建环境 (Fixing the "py-boost does not exist" issue)
# - 移除所有 config set disabled (因为有了正确的安装，不需要禁用了)
# - 将 py-boost 改为 libboost-python
RUN micromamba create -y -p /opt/conda/envs/rdkit_build \
    -c conda-forge \
    python=3.12 \
    numpy \
    cmake \
    make \
    cxx-compiler \
    "boost-cpp>=1.78" \
    "libboost-python>=1.78" \
    eigen \
    cairo \
    freetype \
    pandas \
    rapidjson \
    && micromamba clean -afy

# 4. 下载源码
WORKDIR /rdkit-src
RUN wget -q -O rdkit.tar.gz https://github.com/rdkit/rdkit/archive/refs/tags/${RDKIT_VERSION}.tar.gz \
    && tar -xzf rdkit.tar.gz --strip-components=1 \
    && rm rdkit.tar.gz

# 5. 编译 RDKit
# 既然我们用了标准的 libboost-python，CMake 的查找可能会更顺利，
# 但为了保险，保留你的“暴力路径注入”逻辑，这在交叉编译环境下最稳。
RUN mkdir build && cd build && \
    # 获取路径
    NUMPY_PATH=$(micromamba run -p /opt/conda/envs/rdkit_build python -c 'import numpy; print(numpy.get_include())') && \
    # 查找 libboost_python 库文件 (conda-forge 通常命名为 libboost_python312.so)
    BOOST_PY_LIB=$(find /opt/conda/envs/rdkit_build/lib -name "libboost_python*.so" | head -n 1) && \
    echo "Found Numpy Path: $NUMPY_PATH" && \
    echo "Found Boost Lib: $BOOST_PY_LIB" && \
    # 开始编译
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
    -DBoost_NO_BOOST_CMAKE=ON \
    -DBoost_NO_SYSTEM_PATHS=ON \
    # 显式指定 Python 库路径
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

# 6. 收集依赖库 (精简版)
# 我们只需要拷贝 .so 文件，不需要拷贝整个环境
RUN mkdir -p /rdkit/lib && \
    cp -d /opt/conda/envs/rdkit_build/lib/libboost*.so* /rdkit/lib/ && \
    cp -d /opt/conda/envs/rdkit_build/lib/libpython*.so* /rdkit/lib/ && \
    cp -d /opt/conda/envs/rdkit_build/lib/libRDKit*.so* /rdkit/lib/

# ================================
# Stage 2: Final Image
# ================================
FROM postgres:16-bookworm

ENV PG_MAJOR=16

# 运行时依赖：确保包含 ca-certificates 和其他基础库
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libxrender1 \
    libxext6 \
    libfreetype6 \
    libsm6 \
    libxml2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /rdkit /rdkit

# 配置动态链接库路径
RUN echo "/rdkit/lib" > /etc/ld.so.conf.d/rdkit.conf && ldconfig

COPY postgresql.conf /etc/postgresql/postgresql.conf

ENV POSTGRES_USER=protwis
# 使用官方推荐的启动方式，通过参数加载配置
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]