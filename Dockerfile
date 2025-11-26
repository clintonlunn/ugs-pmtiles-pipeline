FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    gdal-bin \
    jq \
    curl \
    git \
    build-essential \
    libsqlite3-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install tippecanoe
RUN git clone https://github.com/felt/tippecanoe.git /tmp/tippecanoe && \
    cd /tmp/tippecanoe && \
    make -j && \
    make install && \
    cd / && \
    rm -rf /tmp/tippecanoe

# Install gcloud CLI for GCS uploads
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update && apt-get install -y google-cloud-cli

WORKDIR /app

# Copy project files
COPY config/ /app/config/
COPY scripts/ /app/scripts/

# Make scripts executable
RUN chmod +x /app/scripts/*.sh

# Default command - convert all and upload to GCS
CMD ["/app/scripts/cloud-run.sh"]
