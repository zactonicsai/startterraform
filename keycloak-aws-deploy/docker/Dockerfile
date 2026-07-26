# ============================================================================
# Optimized Keycloak image for Artifactory
#
# WHY BOTHER?
# Keycloak has a two-phase startup: a "build" phase that compiles config into
# the image (which DB driver, which features, which providers) and a "run"
# phase. Plain `start` checks whether a rebuild is needed and often does one
# on EVERY boot, adding 20-60 seconds.
#
# Multiply that by every autoscaling event. Baking the build in and running
# `start --optimized` is the single biggest startup-time win available, and it
# directly improves how fast your ASG can respond to a traffic spike.
#
# BUILD-TIME vs RUN-TIME OPTIONS
#   Build-time (fixed in the image):  KC_DB, KC_CACHE, KC_HEALTH_ENABLED,
#                                     KC_METRICS_ENABLED, KC_FEATURES
#   Run-time  (env vars at launch):   KC_DB_URL, passwords, KC_HOSTNAME
# Change a build-time option and you must rebuild the image.
# ============================================================================

ARG KEYCLOAK_VERSION=26.4.0
ARG BASE_IMAGE=quay.io/keycloak/keycloak

# ---------------------------------------------------------------------------
# Stage 1: build
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}:${KEYCLOAK_VERSION} AS builder

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=ispn

# If you have custom providers, themes, or your company's CA certificates,
# copy them in HERE so they are part of the optimized build:
#
# COPY providers/*.jar /opt/keycloak/providers/
# COPY themes/mycompany /opt/keycloak/themes/mycompany
# COPY certs/company-ca.crt /etc/pki/ca-trust/source/anchors/

# jdbc-ping is the cluster discovery method that works on AWS.
# AWS VPCs do not support UDP multicast, which is the classic default, so
# without this each node thinks it is alone: users get randomly logged out
# and hit "invalid state" errors during login. jdbc-ping instead has each
# node register itself in a PostgreSQL table - the database becomes the
# meeting point, which also works perfectly with autoscaling.
RUN /opt/keycloak/bin/kc.sh build --cache-stack=jdbc-ping

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}:${KEYCLOAK_VERSION}

COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Health endpoints live on the management port (9000) in Keycloak 25+,
# separate from application traffic on 8080.
EXPOSE 8080 9000 7800

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
