# ================================
# Stage 1: Builder
# ================================
FROM postgres:16 AS builder

# Set environment variables
ENV PG_MAJOR=16
ENV PATH=/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/postgresql/$PG_MAJOR/bin

# Install necessary packages and dependencies
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

# Define Miniconda installation arguments
ARG INSTALLER_URL_LINUX64="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.4.0-0-Linux-x86_64.sh"
ARG SHA256SUM_LINUX64="b6597785e6b071f1ca69cf7be6d0161015b96340b9a9e132215d5713408c3a7c"
ARG INSTALLER_URL_AARCH64="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.4.0-0-Linux-aarch64.sh"
ARG SHA256SUM_AARCH64="832d48e11e444c1a25f320fccdd0f0fabefec63c1cd801e606836e1c9c76ad51"

# Install Conda
RUN set -x && \
    UNAME_M="$(uname -m)" && \
    if [ "${UNAME_M}" = "x86_64" ]; then \
        INSTALLER_URL="${INSTALLER_URL_LINUX64}"; \
        SHA256SUM="${SHA256SUM_LINUX64}"; \
    elif [ "${UNAME_M}" = "aarch64" ]; then \
        INSTALLER_URL="${INSTALLER_URL_AARCH64}"; \
        SHA256SUM="${SHA256SUM_AARCH64}"; \
    fi && \
    wget "${INSTALLER_URL}" -O miniconda.sh -q && \
    echo "${SHA256SUM} miniconda.sh" > shasum && \
    sha256sum --check --status shasum && \
    mkdir -p /opt/conda && \
    bash miniconda.sh -b -p /opt/conda && \
    rm miniconda.sh shasum && \
    ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc && \
    /opt/conda/bin/conda clean -afy

# Use bash shell with login to keep conda activation across RUN instructions
SHELL ["/bin/bash", "--login", "-c"]

# Remove any existing RDKit directory
RUN rm -fr rdkit

# Download RDKit source code
ARG RDKIT_VERSION=Release_2024_03_3
RUN wget --quiet https://github.com/rdkit/rdkit/archive/refs/tags/${RDKIT_VERSION}.tar.gz \
    && tar -xzf ${RDKIT_VERSION}.tar.gz \
    && mv rdkit-${RDKIT_VERSION} rdkit \
    && rm ${RDKIT_VERSION}.tar.gz

# Add Conda requirements files
ADD requeriments_conda_rdkit_build_x86_64.txt /tmp/requeriments_conda_rdkit_build_x86_64.txt
ADD requeriments_conda_rdkit_build_aarch64.txt /tmp/requeriments_conda_rdkit_build_aarch64.txt

# Create Conda environment for building RDKit
RUN UNAME_M="$(uname -m)" && \
    if [ "${UNAME_M}" = "x86_64" ]; then \
        CONDA_ENV_FILE="/tmp/requeriments_conda_rdkit_build_x86_64.txt"; \
    elif [ "${UNAME_M}" = "aarch64" ]; then \
        CONDA_ENV_FILE="/tmp/requeriments_conda_rdkit_build_aarch64.txt"; \
    fi && \
    conda create -y -c conda-forge --name rdkit_built_dep --file "${CONDA_ENV_FILE}" && \
    conda clean -afy

# Activate environment and install additional Python packages
RUN conda activate rdkit_built_dep && pip install yapf==0.11.1 coverage==3.7.1

# Configure and build RDKit
RUN mkdir /rdkit/build && \
    cd /rdkit/build && \
    conda activate rdkit_built_dep && \
    cmake -DPy_ENABLE_SHARED=1 \
          -DRDK_INSTALL_INTREE=ON \
          -DRDK_INSTALL_STATIC_LIBS=OFF \
          -DRDK_BUILD_CPP_TESTS=ON \
          -DPYTHON_NUMPY_INCLUDE_PATH="$(python -c 'import numpy ; print(numpy.get_include())')" \
          -DBOOST_ROOT="$CONDA_PREFIX" \
          -DBoost_NO_BOOST_CMAKE=OFF \
          -DBoost_NO_SYSTEM_PATHS=OFF \
          -DRDK_BUILD_AVALON_SUPPORT=ON \
          -DRDK_BUILD_CAIRO_SUPPORT=ON \
          -DRDK_BUILD_INCHI_SUPPORT=ON \
          -DRDK_BUILD_PGSQL=ON \
          -DPostgreSQL_CONFIG_DIR=/usr/lib/postgresql/$PG_MAJOR/bin \
          -DPostgreSQL_INCLUDE_DIR="/usr/include/postgresql" \
          -DPostgreSQL_TYPE_INCLUDE_DIR="/usr/include/postgresql/$PG_MAJOR/server" \
          -DPostgreSQL_LIBRARY="/usr/lib/aarch64-linux-gnu/libpq.so.5" \
          ..

# Compile and install RDKit
RUN cd /rdkit/build && make -j $(nproc) && make install

# Set PostgreSQL environment variables to load RDKit
RUN mkdir -p /etc/postgresql/$PG_MAJOR/main/ && \
    echo "LD_LIBRARY_PATH = '/rdkit/lib:$CONDA_PREFIX/lib'" | tee -a /etc/postgresql/$PG_MAJOR/main/environment

# Adjust permissions for RDKit directories
RUN chgrp -R postgres /rdkit && chmod -R g+w /rdkit

# ================================
# Stage 2: Final Image
# ================================
FROM postgres:16

# Set environment variables
ENV PG_MAJOR=16
ENV PATH=/usr/lib/postgresql/$PG_MAJOR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Install necessary packages and set LD_LIBRARY_PATH in one RUN command to minimize layers
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && echo "LD_LIBRARY_PATH = '/rdkit/lib:$CONDA_PREFIX/lib'" >> /etc/postgresql/$PG_MAJOR/main/environment

# Copy RDKit files and PostgreSQL environment configuration from the builder stage
COPY --from=builder /rdkit /rdkit
COPY --from=builder /etc/postgresql/$PG_MAJOR/main/environment /etc/postgresql/$PG_MAJOR/main/environment

# Add custom PostgreSQL configuration file
ADD postgresql.conf /postgresql.conf

# Set environment variables for PostgreSQL user
ENV POSTGRES_USER=protwis
STOPSIGNAL SIGINT

# Define the entrypoint command
CMD export PATH="$PATH:/usr/lib/postgresql/$PG_MAJOR/bin" && \
    bash -i docker-ensure-initdb.sh && \
    cp /postgresql.conf /var/lib/postgresql/data/postgresql.conf && \
    useradd -m -s /bin/bash $POSTGRES_USER && \
    su postgres -l -c 'export LD_LIBRARY_PATH="/rdkit/lib:$CONDA_PREFIX/lib" && \
    postgres -D "$PGDATA"'
