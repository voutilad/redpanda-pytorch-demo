# Operationalizing ML with Redpanda Connect

This is an example of operationalizing a classification model using 
Redpanda Connect with Python. It leverages Python modules from
[Hugging Face](https://huggingface.co) and [PyTorch](https://pytorch.org) with
a pre-tuned sentiment classifier for financial news.

Two examples are provided:

  - an **API approach** that provides an HTTP API for scoring content
    while also caching and persisting classifier output in-memory and,
    optionally, to a Redpanda topic for others to consume

  - an **enrichment workflow** that takes data from one Redpanda
    topic, classifies it, and outputs results to a destination topic

## Requirements

- Python 3.12
- [git lfs](https://git-lfs.com)
- Go 1.22 or so

## Installation

1. Check out the project and submodules:

    ```sh
    git clone https://github.com/voutilad/redpanda-mlops
    git submodule update --init --recursive
    cd redpanda-mlops
    ```

2. Install a Python virtualenv and dependencies:

    ```sh
    python3 -m venv venv
    . venv/bin/activate
    pip install -U pip
    pip install -r requirements.txt
    ```

3. Build Redpanda Connect w/ Python support:

    ```sh
    CGO_ENABLED=0 go build -C rpcp
    ```

## The HTTP Server Approach
The HTTP approach demonstrates a few awesome features of Redpanda Connect:

- **caching**: how can you avoid costly enrichment steps if nothing changed?
- **fan out**: how can you send data to multiple outputs?
- **synchronous responses**: how can you quickly build a request/response API?
- **runtime switcheroos**: how can you swap components across environments?

### Running the HTTP Service
To run in a mode that accepts HTTP POSTs of content to classify, use the
provided `http-server.yaml` and an HTTP client like `curl`.

1. Start up the pipeline (with virtualenv active):

    ```sh
    ./rpcp/rp-connect-python run http-server.yaml
    ```

2. From another terminal, fire off a request with `curl` (and pipe to `jq`
   if you have it):

    ```sh
    curl -s -X POST \
        -d 'Apple adjusted their targets downward.' \
        'http://localhost:8080/sentiment' | jq
    ```

You should get something like:

```json
{
  "label": "negative",
  "metadata": {
    "cache_hit": false
  },
  "score": 0.9963293671607971,
  "text": "Apple adjusted their targets downward."
}
```

### Under the Covers
The pipeline starts off with an `http_server` input, which provides the API
surface area for interacting with clients.

Next, we have an `memory_cache` resource. In some situations, you may want
[other](https://docs.redpanda.com/redpanda-connect/components/caches/about/)
cache backends, like Redis, but this simply uses local memory.

If we look at the pipeline, we'll se the first step is to utilize the cache:

```yaml
    - cache:
        resource: memory_cache
        operator: get
        key: '${!content().string().hash("sha1")}'
```

It computes a key on the fly by decoding the content of the HTTP POST body
into a string and hashing it with the SHA-1 algorithm, all done via bloblang
[interpolation](https://docs.redpanda.com/redpanda-connect/configuration/interpolation/#bloblang-queries).
If we have a hit, the message is replaced with the value from the cache.

Next, we have a conditional `branch` stage to handle cache misses. It checks
if the error flag is set by the previous stage (in this case, a cache miss
results in the error flag being set, so `errored()` evaluates to `true`). If
we've errored, we create a temporary message from the `content()` of the
incoming message. Otherwise, we use `deleted()` and emit nothing.

```yaml
- branch:
    request_map: |
      # on error, we had a cache miss.
      root = if errored() { content() } else { deleted() }
    processors:
      # these run only on the temporary messages from `request_map` evaluation
      # ...
```

This temporary message is then passed into the inner `processors`.

The first inner processor is where our Python enrichment occurs:

```yaml
- python:
    modules:
      - torch
    script: |
      from classifier import get_pipeline

      text = content().decode()
      pipeline = get_pipeline("mps")
      root.text = text

      scores = pipeline(text)
      if scores:
        root.label = scores[0]["label"]
        root.score = scores[0]["score"]
      else:
        root.label = "unlabeled"
        root.score = 0.0
```

Using my [Python integration](https://github.com/voutilad/rp-connect-python),
we can leverage PyTorch and Hugging Face tools in just a few lines of inline
code. There's a global import of the `torch` module (required because of how
embedding Python works) and a runtime import of a local helper module
[classifier](./classifier.py) that wires up the pre-trained model and
tokenizer.

> For more details, see the https://github.com/voutilad/rp-connect-python
> project on the nuances of the bloblang-like features embedded in Python.

To output data, we leverage a runtime decision via the use of resources:

```yaml
output:
  resource: ${RPCN_OUTPUT_MODE:http}

output_resources:
  - label: http
    sync_response: {}
  - label: both
    broker:
      pattern: fan_out
      outputs:
      # ...more details follow
```

At runtime, the `RPCN_OUTPUT_MODE` environment variable dictates which of
the `output_resources` we connect to the pipeline. If set to `http`, or left
undefined, we just use `sync_response` to reply to the HTTP client with the
results. If set to `both`, we use a `broker` to with multiple `fan_out`
output destinations.

> In this current configuration, using `both` will cause an intial cold-start
> latency spike as the connection to the Redpanda cluster is made while
> processing the first request. The connections remain open, so subsequent
> requests don't incur the same cost. 


## The Data Enrichment Approach

TBA