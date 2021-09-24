# Build settings
ARG KEYDB_DIR=/tmp/keydb
ARG REDIS_JSON_GIT=https://github.com/RedisJSON/RedisJSON.git
ARG REDIS_JSON_DIR=/tmp/redisjson

FROM debian:bullseye-slim as keydb
ARG KEYDB_DIR
ARG KEYDB_GIT=https://github.com/EQ-Alpha/KeyDB.git
ARG KEYDB_BRANCH=RELEASE_6
RUN \
    buildDeps=" \
    ca-certificates git build-essential nasm autotools-dev autoconf libjemalloc-dev tcl tcl-dev uuid-dev libcurl4-openssl-dev libssl-dev"; \
    apt-get update; apt-get install -y --no-install-recommends $buildDeps; rm -rf /var/lib/apt/lists/*;
RUN mkdir ${KEYDB_DIR} && git clone ${KEYDB_GIT} ${KEYDB_DIR} && cd ${KEYDB_DIR} && git fetch --all && git checkout ${KEYDB_BRANCH} && git pull
WORKDIR ${KEYDB_DIR}
RUN BUILD_TLS=yes make
RUN mkdir ${KEYDB_DIR}/bin && cp ./src/keydb-* ${KEYDB_DIR}/bin
RUN rm ${KEYDB_DIR}/bin/*.cpp && rm ${KEYDB_DIR}/bin/*.d &&  rm ${KEYDB_DIR}/bin/*.o

### Create the build container
FROM rust:bullseye as redisjson
ARG REDIS_JSON_GIT
ARG REDIS_JSON_DIR
RUN mkdir ${REDIS_JSON_DIR}
RUN apt update && apt install -y git libclang-dev
RUN git clone ${REDIS_JSON_GIT} ${REDIS_JSON_DIR}
WORKDIR ${REDIS_JSON_DIR}
RUN cargo build --release

FROM debian:bullseye-slim as target
ENV GOSU_VERSION 1.10
# Add user and groups
RUN groupadd -r keydb && useradd -r -g keydb keydb
# Install gosu to drop permissions
RUN \
    fetchDeps=" \
        ca-certificates \
        dirmngr \
        gnupg \
        wget"; \
    apt-get update; apt-get install -y --no-install-recommends libcurl4-openssl-dev $fetchDeps; rm -rf /var/lib/apt/lists/*; \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    gpgconf --kill all; \
    rm -r "$GNUPGHOME" /usr/local/bin/gosu.asc; \
    chmod +x /usr/local/bin/gosu; \
    gosu nobody true; \
    apt-get purge -y --auto-remove $fetchDeps
ARG REDIS_JSON_DIR
ARG KEYDB_DIR
ENV REJSON_DIR=/var/lib/rejson
RUN mkdir -p ${REJSON_DIR} /etc/keydb
COPY --from=keydb  ${KEYDB_DIR}/bin/* /usr/local/bin/
COPY --from=keydb ${KEYDB_DIR}/*.conf /etc/keydb
COPY --from=redisjson ${REDIS_JSON_DIR}/target/release/librejson.so ${REJSON_DIR}/librejson.so
RUN \
    sed -i 's/^\(bind .*\)$/# \1/' /etc/keydb/keydb.conf && \
    sed -i 's/^\(daemonize .*\)$/# \1/' /etc/keydb/keydb.conf && \
    sed -i 's/^\(dir .*\)$/# \1\ndir \/data/' /etc/keydb/keydb.conf && \
    sed -i 's/^\(logfile .*\)$/# \1/' /etc/keydb/keydb.conf && \
    sed -i 's/protected-mode yes/protected-mode no/g' /etc/keydb/keydb.conf
RUN \
  mkdir /data && chown keydb:keydb /data && \
  mkdir /flash && chown keydb:keydb /flash
VOLUME /data
WORKDIR /data
ENV KEYDB_PRO_DIRECTORY=/usr/local/bin/
EXPOSE 6379
COPY entrypoint.sh /usr/local/bin/
ENTRYPOINT ["entrypoint.sh"]
CMD ["keydb-server", "/etc/keydb/keydb.conf"]