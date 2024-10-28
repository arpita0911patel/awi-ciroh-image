FROM pangeo/pangeo-notebook:2024.04.08

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH ${NB_PYTHON_PREFIX}/bin:$PATH

# Initial system setup and dependencies
RUN apt-get update -qq --yes > /dev/null && \
    apt-get install -y -qq \
    gnupg2 \
    dbus-x11 \
    firefox \
    xfce4 \
    xfce4-panel \
    xfce4-session \
    xfce4-settings \
    xorg \
    xubuntu-icon-theme \
    curl \
    vim \
    gcc \
    g++ \
    make \
    cmake \
    ninja-build \
    tar \
    git \
    gfortran \
    libgfortran5 \
    sqlite3 \
    sqlite3-dev \
    gdal-bin \
    libgdal-dev \
    bzip2 \
    libexpat1 \
    libexpat1-dev \
    flex \
    bison \
    libudunits2-0 \
    libudunits2-dev \
    zlib1g-dev \
    wget \
    mpich \
    mpich-dev \
    hdf5 \
    hdf5-dev \
    netcdf \
    netcdf-dev \
    netcdf-fortran \
    netcdf-fortran-dev \
    netcdf-cxx \
    netcdf-cxx-dev \
    lld && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js and npm
RUN curl -sL https://deb.nodesource.com/setup_16.x | bash - && \
    apt-get install -y nodejs

# Install TurboVNC
ARG TURBOVNC_VERSION=2.2.6
RUN wget -q "https://sourceforge.net/projects/turbovnc/files/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_amd64.deb/download" -O turbovnc.deb && \
    apt-get update -qq --yes > /dev/null && \
    apt-get install -y ./turbovnc.deb > /dev/null && \
    apt-get remove -y light-locker > /dev/null && \
    rm ./turbovnc.deb && \
    ln -s /opt/TurboVNC/bin/* /usr/local/bin/ && \
    rm -rf /var/lib/apt/lists/*

# Install conda packages
RUN mamba install -n ${CONDA_ENV} -y websockify

# Install Jupyter extensions and tools
RUN export PATH=${NB_PYTHON_PREFIX}/bin:${PATH} && \
    npm install -g npm@7.24.0 && \
    pip install --no-cache-dir \
        https://github.com/jupyterhub/jupyter-remote-desktop-proxy/archive/main.zip && \
    pip install jupyterlab_vim jupyter-tree-download

# Install Google Cloud SDK
RUN apt-get update && \
    apt-get install -y curl gnupg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update -y && \
    apt-get install google-cloud-sdk -y && \
    rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip install spatialpandas easydev colormap colorcet duckdb dask_geopandas hydrotools sidecar && \
    pip install --upgrade colorama && \
    pip install nb_black==1.0.5 && \
    pip install -U --no-cache-dir --upgrade-strategy only-if-needed git+https://github.com/hydroshare/nbfetch.git@hspuller-auth && \
    pip install google-cloud-bigquery dataretrieval

# Enable Jupyter extensions
RUN jupyter server extension enable --py nbfetch --sys-prefix

# Update Jupyter Lab settings
RUN sed -i 's/\"default\": true/\"default\": false/g' /srv/conda/envs/notebook/share/jupyter/labextensions/@axlair/jupyterlab_vim/schemas/@axlair/jupyterlab_vim/plugin.json

# NGEN and T-Route setup
ENV TROUTE_REPO=CIROH-UA/t-route
ENV TROUTE_BRANCH=no-fiona
ENV NGEN_REPO=CIROH-UA/ngen
ENV NGEN_BRANCH=main

# Build Boost
WORKDIR /tmp
RUN wget https://archives.boost.io/release/1.79.0/source/boost_1_79_0.tar.gz && \
    tar -xzf boost_1_79_0.tar.gz && \
    cd boost_1_79_0 && \
    ./bootstrap.sh && ./b2 && ./b2 headers
ENV BOOST_ROOT=/tmp/boost_1_79_0

# Setup for T-Route
WORKDIR /ngen
ENV FC=gfortran NETCDF=/usr/lib/x86_64-linux-gnu/gfortran/modules/
RUN ln -s /usr/bin/python3 /usr/bin/python

# Install T-Route requirements
RUN pip install uv && uv venv
ENV PATH="/ngen/.venv/bin:$PATH"
RUN uv pip install -r https://raw.githubusercontent.com/$TROUTE_REPO/refs/heads/$TROUTE_BRANCH/requirements.txt

# Clone and build T-Route
WORKDIR /ngen/t-route
RUN git clone --depth 1 --single-branch --branch $TROUTE_BRANCH https://github.com/$TROUTE_REPO.git . && \
    git submodule update --init --depth 1 && \
    uv pip install build wheel

# Build T-Route components
RUN sed -i 's/build_[a-z]*=/#&/' compiler.sh && \
    ./compiler.sh no-e && \
    uv pip install --config-setting='--build-option=--use-cython' src/troute-network/ && \
    uv build --wheel --config-setting='--build-option=--use-cython' src/troute-network/ && \
    uv pip install --no-build-isolation --config-setting='--build-option=--use-cython' src/troute-routing/ && \
    uv build --wheel --no-build-isolation --config-setting='--build-option=--use-cython' src/troute-routing/ && \
    uv build --wheel --no-build-isolation src/troute-config/ && \
    uv build --wheel --no-build-isolation src/troute-nwm/

# Clone and build NGEN
WORKDIR /ngen
RUN git clone --single-branch --branch $NGEN_BRANCH https://github.com/$NGEN_REPO.git && \
    cd ngen && \
    git submodule update --init --recursive --depth 1

# Build NGEN
WORKDIR /ngen/ngen
ENV PATH=${PATH}:/usr/lib/mpich/bin

# Common build arguments for NGEN
ARG COMMON_BUILD_ARGS="-DNGEN_WITH_EXTERN_ALL=ON \
    -DNGEN_WITH_NETCDF:BOOL=ON \
    -DNGEN_WITH_BMI_C:BOOL=ON \
    -DNGEN_WITH_BMI_FORTRAN:BOOL=ON \
    -DNGEN_WITH_PYTHON:BOOL=ON \
    -DNGEN_WITH_ROUTING:BOOL=ON \
    -DNGEN_WITH_SQLITE:BOOL=ON \
    -DNGEN_WITH_UDUNITS:BOOL=ON \
    -DUDUNITS_QUIET:BOOL=ON \
    -DNGEN_WITH_TESTS:BOOL=OFF \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_INSTALL_PREFIX=. \
    -DCMAKE_CXX_FLAGS='-fuse-ld=lld'"

# Build NGEN (serial and parallel versions)
RUN cmake -G Ninja -B cmake_build_serial -S . ${COMMON_BUILD_ARGS} -DNGEN_WITH_MPI:BOOL=OFF && \
    cmake --build cmake_build_serial --target all -- -j $(nproc)

# Setup final directories
RUN mkdir -p /dmod/datasets /dmod/datasets/static /dmod/shared_libs /dmod/bin && \
    cp -a ./extern/*/cmake_build/*.so* /dmod/shared_libs/. || true && \
    find ./extern/noah-owp-modular -type f -iname "*.TBL" -exec cp '{}' /dmod/datasets/static \; && \
    cp -a ./cmake_build_serial/ngen /dmod/bin/ngen-serial || true && \
    cd /dmod/bin && \
    (stat ngen-serial && ln -s ngen-serial ngen)

# Set up library path and permissions
RUN echo "/dmod/shared_libs/" >> /etc/ld.so.conf.d/ngen.conf && \
    ldconfig -v && \
    chmod a+x /dmod/bin/*

# Clean up and set final permissions
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

USER ${NB_USER}
WORKDIR /home/${NB_USER}
