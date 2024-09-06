# Putting ML to Work with Redpanda Connect and PyTorch

<div align="center">
  <img src="./img/banner.jpeg" height="45%"
    alt="A redpanda & a python exploring a cave while carrying a torch."
    style="padding: 20px"
  >
</div>

> Who's that little guy in the background? _No idea!_

This is an example of rapidly deploying a tuned classification model by using
Redpanda Connect with Python. It leverages Python modules from
[Hugging Face](https://huggingface.co) and [PyTorch](https://pytorch.org) with
a pre-tuned sentiment classifier for financial news derived from Meta's
[RoBERTa base model](https://huggingface.co/FacebookAI/roberta-base).

Two examples are provided:

  - an **API service** that provides an HTTP API for scoring content
    while also caching and persisting classifier output in-memory and,
    optionally, to a Redpanda topic for others to consume

  - an **stream analytics pipeline** that takes data from one Redpanda
    topic, classifies it, and routes output to a destination topic
    while _reusing the same pipeline_ from the API approach

The model used is originally from Hugging Face user `mrm8448` and provides
a fine-tuned financial news implementation of Meta's RoBERTa
transformer-based language model:

https://huggingface.co/mrm8488/distilroberta-finetuned-financial-news-sentiment-analysis

> It's included as a git submodule, but if you're viewing this README
> via Github's web UI and trying to click the submodule link, they
> sadly don't support links out to non-Github submodules!


## Requirements

- Python 3.12
- [`git lfs`](https://git-lfs.com)
- Go 1.22 or so
- Redpanda or [Redpanda Serverless](https://cloud.redpanda.com/sign-up/)
- [`rpk`](https://docs.redpanda.com/current/get-started/rpk-install/)
- `jq` (optional)


## Installation

On macOS or Linux distros, you can copy and paste these commands to
get up and running quickly:

1. Clone the project and its submodules:

```sh
git clone https://github.com/voutilad/redpanda-pytorch-demo

cd redpanda-pytorch-demo

git submodule update --init --recursive
```

2. Install a Python virtualenv and dependencies:

```sh
python3 -m venv venv

source venv/bin/activate

pip install -U pip

pip install -r requirements.txt
```

3. Build the Redpanda Connect w/ embedded Python fork:

```sh
CGO_ENABLED=0 go build -C rpcp
```


## Preparing Redpanda

We need a few topics created for our examples. Assuming you've installed
[rpk](https://docs.redpanda.com/current/get-started/rpk-install/) and have
a profile that's authenticated to your Redpanda cluster, you can run the
following commands:

```sh
rpk topic create \
  news positive-news negative-news neutral-news unknown-news -p 5
```

> If using Redpanda Serverless, you should be able to use `rpk auth login`
> to create your profile.

If using a Redpanda instance that requires authentication, such as Redpanda
Serverless, create a Kafka user and ACLs that allow the principal to both
produce and consume from the above topics as well as create a consumer group:

```sh
rpk security user create demo --password demo

rpk security acl create \
  --allow-principal "User:demo" \
  --operation read,write,describe \
  --topic news,positive-news,negative-news,neutral-news,unknown-news \
  --group sentiment-analyzer
```

> Feel free to use a different password!


## The HTTP API Server

The HTTP API server example demonstrates some awesome features of Redpanda
Connect:

- Avoiding costly compute by **caching** results
- Distributing data to multiple outputs via **fan out**
- Providing **synchronous responses** to HTTP clients for an interactive API
- Reusing Redpanda Components via **composable resources** to reduce code
- Using runtime data inspection to **route based on ML output**


### Running the HTTP Service

This example relies on environment variables for some runtime configuration.
You'll need to set a few depending on where you're running Redpanda:

- `REDPANDA_BROKERS`: list of seed brokers (defaults to "localhost:9092")
- `REDPANDA_TLS`: boolean flag for enabling TLS (defaults to "false")
- `REDPANDA_SASL_USERNAME`: Redpanda Kafka API principal name (no default)
- `REDPANDA_SASL_PASSWORD`: Redpanda Kafka API principal name (no default)
- `REDPANDA_SASL_MECHANISM`: SASL mechanism to use (defaults to "none")
- `REDPANDA_TOPIC`: Base name of the topics (defaults to "news")

To run in a mode that accepts HTTP POSTs of content to classify, use the
provided `http-server.yaml` and an HTTP client like `curl`.

0. Set any of your environment variables to make things easier:

```sh
export REDPANDA_BROKERS=tktktktktkt.any.us-east-1.mpx.prd.cloud.redpanda.com:9092
export REDPANDA_TLS=true
export REDPANDA_SASL_USERNAME=demo
export REDPANDA_SASL_PASSWORD=demo
export REDPANDA_SASL_MECHANISM=SCRAM-SHA-256
```

> The above is a faux config for Redpanda Serverless and matches the details we
> created in [Preparing Redpanda](#preparing-redpanda) above.

1. With your virtualenv active, start up the HTTP service:

```sh
./rpcp/rp-connect-python run -r python.yaml http-server.yaml
```

2. From another terminal, fire off a request with `curl` (and pipe to `jq`
   if you have it):

```sh
curl -s -X POST \
    -d "The latest recall of Happy Fun Ball has sent ACME's stock plummeting." \
    'http://localhost:8080/sentiment' | jq
```

You should get something like this in response:

```json
{
  "label": "negative",
  "metadata": {
    "cache_hit": false,
    "sha1": "d7452c7cc882d1c690635cac92945e815947708d"
  },
  "score": 0.9984525442123413,
  "text": "The latest recall of Happy Fun Ball has sent ACME's stock plummeting."
}
```

On the Redpanda side, you'll notice we don't get anything written to the
topics! The next section will go into more detail, but for now restart the
service with a new environment variable:

```sh
REDPANDA_OUTPUT_MODE=both ./rpcp/rp-connect-python \
  run -r python.yaml http-server.yaml
```

Now, submit the same data as before:

```sh
curl -s -X POST \
    -d "The latest recall of Happy Fun Ball has sent ACME's stock plummeting." \
    'http://localhost:8080/sentiment' | jq
```

You should get the same JSON reply back. _So what's different?_

Use `rpk` and consume from our topics:

```sh
rpk topic consume positive-news neutral-news negative-news --offset :end
```

You should see a result from our `negative-news` topic:

```json
{
  "topic": "negative-news",
  "key": "d7452c7cc882d1c690635cac92945e815947708d",
  "value": "{\"label\":\"negative\",\"metadata\":{\"cache_hit\":false,\"sha1\":\"d7452c7cc882d1c690635cac92945e815947708d\"},\"score\":0.9984525442123413,\"text\":\"The latest recall of Happy Fun Ball has sent ACME's stock plummeting.\"}",
  "timestamp": 1725628216383,
  "partition": 4,
  "offset": 0
}
```


### Under the Covers

Now, for a guided walkthrough of how it works! This section breaks down how
the configuration in [http-server.yaml](./http-server.yaml) does what it
does.


#### Receiving HTTP POSTs

The pipeline starts off with an `http_server` input, which provides the API
surface area for interacting with clients:

```yaml
input:
  http_server:
    address: 127.0.0.1:8080
    path: /sentiment
```

The `http_server` can do a lot more than this, including support TLS for
secure communication as well as support websocket connections. In this case,
we keep it simple: clients need to POST a body of text to the `/sentiment`
path on our local web server.


#### Using Caching to Reduce Stress on the Model

Next, we have an `memory_cache` resource. In some situations, you may want
[other](https://docs.redpanda.com/redpanda-connect/components/caches/about/)
cache backends, like Redis/Valkey, but this simply uses local memory.

Caches are designed to be access from multiple components, so they start of
defined in a `cache_resources` list:

```yaml
cache_resources:
  - label: memory_cache
    memory:
      default_ttl: 5m
      compaction_interval: 60s
```

Here we're defining a single cache, called `memory_cache`. You can call it
(almost) anything you want. We'll use the `label` to refer to the cache
instance.


##### Cache Lookups

If we now look at the first stage in the pipeline, we'll see the first step
is to utilize the cache for a lookup:

```yaml
pipeline:
  processors:
    - cache:
        resource: memory_cache
        operator: get
        key: '${!content().string().hash("sha1").encode("hex")}'
```

Here the `cache` `processor` uses our cache resource we defined, referenced
by name/label.

It computes a key on the fly by decoding the content of the HTTP POST body
into a string and hashing it with the SHA-1 algorithm, all done via bloblang
[interpolation](https://docs.redpanda.com/redpanda-connect/configuration/interpolation/#bloblang-queries).
If we have a hit, the message is replaced with the value from the cache.

But what about if we _don't_ have a cache hit?


##### Cache Misses

We use a conditional `branch` stage to handle cache misses. It checks
if the error flag is set by the previous stage (in this case, a cache miss
results in the error flag being set, so `errored()` evaluates to `true`). If
we've errored, we create a temporary message from the `content()` of the
incoming message. Otherwise, we use `deleted()` to emit nothing.

```yaml
- branch:
    request_map: |
      # on error, we had a cache miss.
      root = if errored() { content() } else { deleted() }
    processors:
      # these run only on the temporary messages from `request_map` evaluation
      # ...
```

> This can be a tad confusing at first. Essentially, you're defining/creating
> a temporary message to pass to a totally different pipeline of processors.
> In practice, this message will be based on the actual incoming message...
> but it doesn't have to be!

This temporary message is then passed into the inner `processors`.

We'll talk about updated the cache momentarily.


#### Analyzing Sentiment with PyTorch / Hugging Face

The first inner processor is where our Python enrichment occurs. You'll notice
it looks super boring!

```yaml
        processors:
          - resource: python
```

In this case, we're referencing a _processor resource_ that's defined
elsewhere. In this case, it's the [python.yaml](./python.yaml) you
passed with the `-r` argument to Redpanda Connect.

If you look in that file, you'll see a resource definition in a similar format
to how our cache resource was defined. The important parts are repeated below:

```yaml
python:
  modules:
    - torch
  script: |
    from classifier import get_pipeline

    device = environ.get("DEMO_PYTORCH_DEVICE", "cpu")

    text = content().decode()
    pipeline = get_pipeline(device=device)
    root.text = text

    scores = pipeline(text)
    if scores:
      root.label = scores[0]["label"]
      root.score = scores[0]["score"]
    else:
      root.label = "unlabeled"
      root.score = 0.0
```

Using the [Python integration](https://github.com/voutilad/rp-connect-python),
we can leverage PyTorch and Hugging Face tools in just a few lines of inline
code.

There's a global import of the `torch` module (required because of how
embedding Python works) and a runtime import of a local helper module
[classifier](./classifier.py) that wires up the pre-trained model and
tokenizer.

> Q: What about GPUs? Does this work with GPUs?
> A: Yes. The code is defaulting right now to a "cpu" device, but you can
>    change the argument to `get_pipeline()` in the Python code and pass
>    an appropriate value that PyTorch can use. For instance, if you're
>    on macOS with Apple Silicon, use `"mps"`. See the
>    [torch.device](https://pytorch.org/docs/stable/tensor_attributes.html#torch.device)
>    docs for details on supported values. To do this in the demo, you
>    can set the environment variable `DEMO_PYTORCH_DEVICE` to the type
>    you want to use.

For more details on how Python integrates with Redpanda Connect, see the
https://github.com/voutilad/rp-connect-python project on the nuances of
the bloblang-like features embedded in Python. It's beyond the scope of
this demonstration.

At this point, we've taken what was our boring message of just text and
created a _structured message_ with multiple fields that looks like:

```json
{ "text": "The original text!", "label": "positive", "score": 0.999 }
```

#### Updating the Cache
Now that we've done the computationally heavy part of applying the ML model,
we want to update the cache with the results so we don't have to repeat
ourselves for the same input.

In this case, we do it in a two step process for reasons we'll see later:

```yaml
          - mutation: |
              # compute a sha1 hash as a key
              root.metadata.sha1 = this.text.hash("sha1").encode("hex")
          - cache:
              resource: memory_cache
              operator: set
              key: '${!this.metadata.sha1}'
              value: '${!content()}'
```

The first step above is computing the sha-1 hash of the text we saved from
the original message. We tuck this in a nested field.

Then, we have another instance of a `cache` processor that references the
_same cache resource_ as before. (See how handy resources are?) In this
case, however, we're using a `set` operation _and_ providing the new
value to store. The key to use is a simple bloblang interpolation
that points to our just-computed sha-1 hash.

The tricky thing is the value: we use `content()` to store the full
payload of the message. It's not intuitive! The `cache` processor doesn't
use the message itself...you need to interpolate the message content into
a value to insert into the cache. Confusing!

#### Rejoining from our Branch
If we had a cache miss, we're now at the end of our branch operation and
we need to convert that temporary message to something permanent. Did you
forget we've been working with a _temporary_ messsage? I bet you did.

The tail end of the `branch` config tells the processor how to convert that
temporary message, if it exists, into a real message to pass onwards:

```yaml
        result_map: |
          root = this
          root.metadata.cache_hit = false
```

In this case it's simple: we're copying `this` (the temporary message) to the
new message (i.e. `root`) and also setting a new nested field at the same time.
In this case, we mention we had a cache miss. This way we can see if we're
actually hitting the cache or not so all your work won't be for naught.

#### Last Stop before Output
Lastly, there's a trivial `mutation` step to set the nested `cache_hit` field
if it doesn't exist. Pretty simple. If it's non-existent, then we never went
down the branch path...which means we must have had a cache hit:

```yaml
    - mutation: |
        root.metadata.cache_hit = this.metadata.cache_hit | true
```

#### Getting Data to its Final Destination
Here we use more resource magic to make the outputs toggle-able via the
environment variable `DEMO_OUTPUT_MODE`. We start off with a trivial
`output` definition that just references our resource:

```yaml
output:
  resource: ${DEMO_OUTPUT_MODE:http}
```

Using interpolation, we pull the value from the environment. If it's
not defined, we default to `"http"` as the value.

Now we can define our `output_resources`. You could put these in their own
file, but that's an exercise left to the reader.

Let's take a look at them individually.


##### HTTP Response

Since this is an HTTP API, it's following what some call a _request/reply_
protocol. The client sends some data (via a POST, in this case) and expects
a response back. To do this, we use the `sync_response` component which
will do this automatically:

```yaml
output_resources:
  # Send the HTTP response back to the client.
  - label: http
    sync_response: {}
```

##### Sinking Data into Multiple Redpanda Topics

Other applications might benefit from our work enriching this data, so let's
put the data in Redpanda. We can make everyone's lives easier by sorting the
data based on the sentiment label: `positive`, `negative`, or (in the event
of a failure) `neutral`. This is where our multiple topics comes into play!

```yaml
  # Send the data to Redpanda.
  - label: redpanda
    kafka_franz:
      seed_brokers:
        - ${REDPANDA_BROKERS:localhost}
      topic: "${!this.label | unknown}-${REDPANDA_TOPIC:news}"
      key: ${!this.metadata.sha1}
      batching:
        count: 1000
        period: 5s
      tls:
        enabled: ${REDPANDA_TLS:false}
      sasl:
        - mechanism: ${REDPANDA_SASL_MECHANISM:none}
          username: ${REDPANDA_SASL_USERNAME:}
          password: ${REDPANDA_SASL_PASSWORD:}
```

You can read the details on configuring the `kafka_franz` connector in the
[docs](https://docs.redpanda.com/redpanda-connect/components/outputs/kafka_franz/)
so I won't go into detail here. The important part is the `topic` configuration.

You should notice this is a combination of _bloblang and environment variable_
interpolation. This lets the output component programmatically define the
target topic and lets us route messages.

Lastly, we're reusing that sha-1 hash as the key to demonstrate how that, too,
can be programmatic via interpolation.


##### Why Not Both? Using Fan Out.

Let's say we want to **both** reply to the client (to be helpful and polite) as
well as save the data in Redpanda for others. We can use a `broker` output
that lets us define the pattern of routing messages across multiple outputs.

In this case, we use `fan_out` to duplicate messages to all defined outputs.

Since we already defined our two outputs above as part of our
`output_resources`, this is super simple! We can just use `resource` outputs
that take a named resource by label so we don't have to repeat ourselves.

```yaml
  # Do both: send to Redpanda and reply to the client.
  - label: both
    broker:
      pattern: fan_out
      outputs:
        - resource: http
        - resource: redpanda
```

> In this current configuration, using `both` will cause an initial cold-start
> latency spike as the connection to the Redpanda cluster is made while
> processing the first request. This will appear as a delay to the http client
> calling the service, but subsequent requests won't have this penalty.


## The Data Enrichment Approach

Using what you learned above, we can easily build a _data enrichment pipeline_
sourcing data from an input Redpanda topic, performing the same sentiment
analysis we configured in [python.yaml](./python.yaml), and route the output
to different topics just like before.

In this case, we use both `kafka_franz` `input` _and_ `output`. Most
importantly, we can _reuse_ the same Python pipeline component as it's already
defined in a separate resource file.

Running this example is similar to the previous. Just change the pipeline file:

```sh
./rpcp/rp-connect-python run -r python.yaml enrichment.yaml
```

For testing, you can produce data to your input topic using `rpk`:

```sh
echo 'The Dow closed at a record high today on news that aliens are real' \
  | rpk topic produce news
```

And consume the output:


```sh
rpk topic consume \
  positive-news negative-news neutral-news unknown-news \
  --offset :end
```


### Sourcing Data

This is pretty simple using a `kafka_franz` input. You'll notice that the real
difference here is the `consumer_group` setting. This will let us properly
scale up if needed and help with tracking committed offsets in the stream.

```yaml
input:
  kafka_franz:
    seed_brokers:
      - ${REDPANDA_BROKERS:localhost:9092}
    topics:
      - ${REDPANDA_TOPIC:news}
    consumer_group: ${REDPANDA_CONSUMER_GROUP:sentiment-analyzer}
    batching:
      count: 1000
      period: 5s
    tls:
      enabled: ${REDPANDA_TLS:false}
    sasl:
      - mechanism: ${REDPANDA_SASL_MECHANISM:none}
        username: ${REDPANDA_SASL_USERNAME:}
        password: ${REDPANDA_SASL_PASSWORD:}
```

It's worth pointing out the `batching` section. The `python` component can
process batches more efficiently than single messages, so it's recommended to
batch when you can.


### The Enrichment Pipeline

Our pipeline logic becomes trivial thanks to resources:

```yaml
pipeline:
  processors:
    - resource: python
```

That's it! It's _that_ easy.


### Sinking Data

We use the same interpolation approaches as before with one exception. See
if you can spot it:

```yaml
output:
  kafka_franz:
    seed_brokers:
      - ${REDPANDA_BROKERS:localhost}
    topic: "${!this.label | unknown}-${REDPANDA_TOPIC:news}"
    key: ${!meta("kafka_key")}
    batching:
      count: 1000
      period: 5s
    tls:
      enabled: ${REDPANDA_TLS:false}
    sasl:
      - mechanism: ${REDPANDA_SASL_MECHANISM:none}
        username: ${REDPANDA_SASL_USERNAME:}
        password: ${REDPANDA_SASL_PASSWORD:}
```

Instead of a sha-1 hash, which we don't really need or care about, we re-use
the original key (if any) from the incoming message. If data is produced to
our input topic with a key, we'll re-use that key.


## Wrapping Up

Hopefully this is helpful in both explaining the intricacies of Redpanda
Connect end-to-end as well as illustrating a useful example of using a
low-code approach to building enrichment services and pipelines!


## About the Banner Image

The cute Redpanda and Python exploring a cave was created by
[Bing Image Creator](https://www.bing.com/images/create).