# ================================
# Stage 1: Builder
# ================================
FROM postgres:16 AS builder

# 设置主要环境变量
ENV PG_MAJOR=16

# 添加 Conda 依赖文件
COPY requirements_conda_rdkit_build_x86_64.txt /tmp/requirements_conda_rdkit_build_x86_64.txt
COPY requirements_conda_rdkit_build_aarch64.txt /tmp/requirements_conda_rdkit_build_aarch64.txt

# 安装必要的包和依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    wget \
    git \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libfreetype6 \
    libxrender1 \
    mercurial \
    openssh-client \
    procps \
    subversion \
    bzip2 \
    ca-certificates \
    curl \
    gnupg \
    && dpkg --remove-architecture armhf || true \
    && echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && apt-get update && apt-get install -y --no-install-recommends \
        postgresql-server-dev-$PG_MAJOR \
        postgresql-server-dev-all \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 定义 Miniconda 安装参数
ARG INSTALLER_URL_LINUX64="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.4.0-0-Linux-x86_64.sh"
ARG SHA256SUM_LINUX64="b6597785e6b071f1ca69cf7be6d0161015b96340b9a9e132215d5713408c3a7c"
ARG INSTALLER_URL_AARCH64="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.4.0-0-Linux-aarch64.sh"
ARG SHA256SUM_AARCH64="832d48e11e444c1a25f320fccdd0f0fabefec63c1cd801e606836e1c9c76ad51"

# 安装 Conda 到特定路径基于架构
RUN set -x && \
    UNAME_M="$(uname -m)" && \
    if [ "${UNAME_M}" = "x86_64" ]; then \
        INSTALLER_URL="${INSTALLER_URL_LINUX64}"; \
        SHA256SUM="${SHA256SUM_LINUX64}"; \
        CONDA_INSTALL_PATH="/opt/conda_builder_x86_64"; \
        CONDA_ENV_FILE="/tmp/requirements_conda_rdkit_build_x86_64.txt"; \
    elif [ "${UNAME_M}" = "aarch64" ]; then \
        INSTALLER_URL="${INSTALLER_URL_AARCH64}"; \
        SHA256SUM="${SHA256SUM_AARCH64}"; \
        CONDA_INSTALL_PATH="/opt/conda_builder_aarch64"; \
        CONDA_ENV_FILE="/tmp/requirements_conda_rdkit_build_aarch64.txt"; \
    fi && \
    wget "${INSTALLER_URL}" -O miniconda.sh -q && \
    echo "${SHA256SUM} miniconda.sh" > shasum && \
    sha256sum --check --status shasum && \
    rm -rf ${CONDA_INSTALL_PATH} && \
    bash miniconda.sh -b -p ${CONDA_INSTALL_PATH} && \
    rm miniconda.sh shasum && \
    ln -s ${CONDA_INSTALL_PATH}/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". ${CONDA_INSTALL_PATH}/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc && \
    # 创建 Conda 到 /usr/local/bin 的符号链接
    ln -s ${CONDA_INSTALL_PATH}/bin/conda /usr/local/bin/conda && \
    # 清理 Conda
    ${CONDA_INSTALL_PATH}/bin/conda clean -afy && \
    conda create -y -c conda-forge --name rdkit_built_dep --file "${CONDA_ENV_FILE}" && \
    conda clean -afy && \
    conda run -n rdkit_built_dep pip install yapf==0.11.1 coverage==3.7.1

# 移除任何现有的 RDKit 目录
RUN rm -fr rdkit
# 下载 RDKit 源代码
ARG RDKIT_VERSION=Release_2025_03_1
RUN wget --quiet https://github.com/rdkit/rdkit/archive/refs/tags/${RDKIT_VERSION}.tar.gz \
    && tar -xzf ${RDKIT_VERSION}.tar.gz \
    && mv rdkit-${RDKIT_VERSION} rdkit \
    && rm ${RDKIT_VERSION}.tar.gz

# 配置并构建 RDKit
RUN UNAME_M="$(uname -m)" && \
    mkdir /rdkit/build && \
    cd /rdkit/build && \
    conda run -n rdkit_built_dep cmake -DPy_ENABLE_SHARED=1 \
        -DRDK_INSTALL_INTREE=ON \
        -DRDK_INSTALL_STATIC_LIBS=OFF \
        -DRDK_BUILD_CPP_TESTS=ON \
        -DPYTHON_NUMPY_INCLUDE_PATH="$(conda run -n rdkit_built_dep python -c 'import numpy ; print(numpy.get_include())')" \
        -DBOOST_ROOT="${CONDA_INSTALL_PATH}" \
        -DBoost_INCLUDEDIR="${CONDA_INSTALL_PATH}/include" \
        -DBoost_LIBRARYDIR="${CONDA_INSTALL_PATH}/lib" \
        -DBoost_NO_BOOST_CMAKE=OFF \
        -DBoost_NO_SYSTEM_PATHS=OFF \
        -DRDK_BUILD_AVALON_SUPPORT=ON \
        -DRDK_BUILD_CAIRO_SUPPORT=ON \
        -DRDK_BUILD_INCHI_SUPPORT=ON \
        -DRDK_BUILD_PGSQL=ON \
        -DPostgreSQL_CONFIG_DIR=/usr/lib/postgresql/$PG_MAJOR/bin \
        -DPostgreSQL_INCLUDE_DIR="/usr/include/postgresql" \
        -DPostgreSQL_TYPE_INCLUDE_DIR="/usr/include/postgresql/$PG_MAJOR/server" \
        -DPostgreSQL_LIBRARY="/usr/lib/${UNAME_M}-linux-gnu/libpq.so.5" \
        .. && \
    conda run -n rdkit_built_dep make -j $(nproc) && \
    conda run -n rdkit_built_dep make install && \
    # 调整 RDKit 目录权限
    chgrp -R postgres /rdkit && chmod -R g+w /rdkit

# ================================
# Stage 2: Final Image
# ================================
FROM postgres:16

# 设置环境变量
ENV PG_MAJOR=16
ENV PATH=/usr/lib/postgresql/$PG_MAJOR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 安装必要的包并设置 LD_LIBRARY_PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/postgresql/$PG_MAJOR/main/ \
    && echo "LD_LIBRARY_PATH='/rdkit/lib'" >> /etc/postgresql/$PG_MAJOR/main/environment

# 从构建阶段复制 RDKit 文件
COPY --from=builder /rdkit /rdkit

# 添加自定义 PostgreSQL 配置文件
COPY postgresql.conf /postgresql.conf

# 设置 PostgreSQL 用户环境变量
ENV POSTGRES_USER=protwis
STOPSIGNAL SIGINT

# 定义入口命令
CMD export LD_LIBRARY_PATH="/rdkit/lib" && \
    export PATH="$PATH:/usr/lib/postgresql/$PG_MAJOR/bin" && \
    bash -i docker-ensure-initdb.sh && \
    cp /postgresql.conf /var/lib/postgresql/data/postgresql.conf && \
    useradd -m -s /bin/bash $POSTGRES_USER && \
    su postgres -l -c 'postgres -D "$PGDATA"'
