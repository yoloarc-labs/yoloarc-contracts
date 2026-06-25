# Marking 做市 keeper 容器
# 基于官方 Foundry 镜像 (含 forge/cast), 容器内每 N 秒用 cast 调 Marking.executeMarketControl()
# 签名用 ENV 明文私钥 (keeper 账户在 Marking 上授 KEEPER_ROLE, 最小权限)
# 构建: docker build -t yoloarc-marking-keeper docker/keeper
# 注意: ARM 主机 (Apple Silicon) 构建需加 --platform linux/amd64
FROM ghcr.io/foundry-rs/foundry:latest

WORKDIR /app

# 拷贝 keeper 脚本
COPY keeper.sh entrypoint.sh /app/
RUN chmod +x /app/keeper.sh /app/entrypoint.sh

# 默认每 5 分钟一次, 可用 INTERVAL_SECONDS 覆盖
ENV INTERVAL_SECONDS=300 \
    CHAIN_ID=56 \
    GAS_LIMIT=300000

ENTRYPOINT ["/app/entrypoint.sh"]
