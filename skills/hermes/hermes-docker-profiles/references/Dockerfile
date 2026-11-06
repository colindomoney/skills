# Pinned by digest, not tag. To move the pin, see "Bump the image" in SKILL.md.
FROM nousresearch/hermes-agent@sha256:adb7890916de63245523492be8f68f9d2095fecbec4e2a6dab7960381f0fc002

USER root

# Add only what the image lacks, for example:
#   RUN npm install -g pnpm@10 && npm cache clean --force

# ENTRYPOINT, CMD, HERMES_HOME and the hermes user come from the base image,
# which drops to uid 10000 at runtime. Don't redefine them.
