FROM ubuntu:24.04

# Install core dependencies
RUN apt-get update && apt-get install -y apt-transport-https ca-certificates gnupg wget curl \
    mysql-client postgresql-client \
    openssl telnet ssh iputils-ping vim net-tools tcpdump bc jq yq

# Install kubectl
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
RUN chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
RUN echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
RUN chmod 644 /etc/apt/sources.list.d/kubernetes.list
RUN apt-get update && apt-get install -y kubectl

# Install MongoDB database tools
RUN wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2404-x86_64-100.11.0.deb \
    && apt install -y ./mongodb-database-tools-ubuntu2404-x86_64-100.11.0.deb \
    && rm -f mongodb-database-tools-ubuntu2404-x86_64-100.11.0.deb

# Install milvus backup client
RUN wget -qO- https://github.com/zilliztech/milvus-backup/releases/download/v0.5.2/milvus-backup_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin

# Install IBM Cloud CLI
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
RUN ibmcloud plugin install cloud-object-storage

# Install mc client
RUN curl https://dl.min.io/client/mc/release/linux-amd64/mc --create-dirs -o /usr/local/bin/minio-binaries/mc
RUN chmod +x /usr/local/bin/minio-binaries/mc
ENV PATH="$PATH:/usr/local/bin/minio-binaries/"