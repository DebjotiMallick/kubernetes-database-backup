FROM ubuntu:24.04

WORKDIR /scripts

COPY ./scripts/ /scripts/
RUN chmod +x /scripts/*

# Install core dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget \
    mysql-client unzip bc jq yq \
    && rm -rf /var/lib/apt/lists/*  

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm awscliv2.zip

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install PostgreSQL Client 18
RUN install -d /usr/share/postgresql-common/pgdg \
    && curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && . /etc/os-release \
    && sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main' > /etc/apt/sources.list.d/pgdg.list" \
    && apt update \
    && apt install -y postgresql-client-18

# Install MongoDB database tools
RUN wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2404-x86_64-100.11.0.deb \
    && apt-get install -y ./mongodb-database-tools-ubuntu2404-x86_64-100.11.0.deb \
    && rm -f mongodb-database-tools-ubuntu2404-x86_64-100.11.0.deb

# Install milvus backup client
RUN wget -qO- https://github.com/zilliztech/milvus-backup/releases/download/v0.5.2/milvus-backup_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin

# Install mc client
RUN curl https://dl.min.io/client/mc/release/linux-amd64/mc --create-dirs -o /usr/local/bin/minio-binaries/mc \
    && chmod +x /usr/local/bin/minio-binaries/mc
ENV PATH="$PATH:/usr/local/bin/minio-binaries/"