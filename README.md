# Operationalizing ML with Redpanda Connect

More details to come...

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

4. Start up the pipeline (with virtualenv active):

    ```sh
    ./rpcp/rp-connect-python run pipeline.yaml
    ```

5. From another terminal, fire off a request with `curl` (and pipe to `jq`
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
