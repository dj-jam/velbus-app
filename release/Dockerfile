# Release binary-only Docker image. The private source tree is never a Docker context.
# Image platform is chosen by the public GitHub Actions runner.
FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:de0ee358cdd672f7017a003bed21e9ac9ed48a27c922a59b18175b6e82fa7fee
ARG BUILD_ARCH
ARG BUILD_VERSION
LABEL io.hass.type="app" \
      io.hass.version="${BUILD_VERSION}" \
      io.hass.arch="${BUILD_ARCH}" \
      org.opencontainers.image.source="https://github.com/dj-jam/velbus-app" \
      org.opencontainers.image.title="Velbus Manager 2.0 Beta"
RUN apt-get update && apt-get install -y --no-install-recommends nginx curl iproute2 gosu && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --chown=app:app payload/ /app/
COPY runtime/nginx.conf /app/ha-app/nginx.conf
COPY runtime/launch.sh /app/ha-app/launch.sh
RUN groupadd --gid 18 haos-dialout && usermod -a -G dialout,haos-dialout app && \
    chmod 0755 /app/ha-app/launch.sh && \
    mkdir -p /data /tmp/nginx-client /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi && \
    chown -R "$APP_UID" /data /tmp/nginx-* && chown "$APP_UID" /app/ha-app
ENV ASPNETCORE_ENVIRONMENT=Production MANAGER_USERDATA=/data SNAP_DATA=/data
# Start the entrypoint as root only to repair Supervisor-owned /data mounts.
# Runtime services MUST be started as unprivileged app using gosu.
USER root
EXPOSE 8099
ENTRYPOINT ["/app/ha-app/launch.sh"]
