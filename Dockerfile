###################################################
# Build our Go dependencies.
###################################################
FROM golang:1.23-bookworm AS go-builder
COPY ./rpcp /go/src/rp-connect-python
ENV CGO_ENABLED=0
WORKDIR /go/src/rp-connect-python
RUN go mod download
RUN go build

###################################################
# Install any Python modules we need.
###################################################
FROM python:3.12-slim-bookworm AS python-builder
COPY requirements.txt .
RUN python -m venv venv
RUN ./venv/bin/pip install -U pip
RUN ./venv/bin/pip install -r requirements.txt

###################################################
# Assemble our resulting Docker image.
###################################################
FROM python:3.12-slim-bookworm
LABEL description="This image is a packaged example of using Redpanda Connect \
to create a sentiment analysis service."

## Configure a non-root user.
RUN groupadd -g 9092 redpanda
RUN useradd -u 9092 -g 9092 redpanda -d /app -m
RUN mkdir /app/__pycache__ && chown 9092:9092 /app/__pycache__
WORKDIR /app

## Copy assets from the other Docker images.
COPY --from=go-builder --chown=root:root --chmod=755 \
    /go/src/rp-connect-python/rp-connect-python /app/rp-connect-python
COPY --from=python-builder --chown=root:root --chmod=755 \
    /venv /app/venv

## Configure how we interface with the outside world.
ENV PATH="/app/venv/bin:${PATH}" \
    HOST="0.0.0.0" \
    PORT=8080
EXPOSE 8080/tcp
USER 9092:9092
WORKDIR /app
ENTRYPOINT ["./rp-connect-python"]
CMD ["run", "-r", "python.yaml", "http-server.yaml"]

## Copy in our ML model.
COPY --chown=root:root --chmod=744 \
    model /app/model

## Copy in our pipeline assets.
COPY --chown=root:root --chmod=644 \
    classifier.py /app/
COPY --chown=root:root --chmod=644 \
    enrichment.yaml http-server.yaml python.yaml /app/
