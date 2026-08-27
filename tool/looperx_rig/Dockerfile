FROM arm32v7/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libegl1 libegl-mesa0 libgles2 libglapi-mesa libgbm1 libgl1-mesa-dri \
      libdrm2 libexpat1 zlib1g libstdc++6 xz-utils gcc libc6-dev \
  && rm -rf /var/lib/apt/lists/*
COPY seqshim.c /tmp/seqshim.c
RUN gcc -shared -fPIC -O2 -o /usr/local/lib/libseqshim.so /tmp/seqshim.c
