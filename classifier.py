"""
Wrapper around our HuggingFace code to make our RPCN pipepline cleaner and to
avoid multiple loads of the same model and tokenizer.
"""
from transformers import (
    pipeline, AutoModelForSequenceClassification, PreTrainedTokenizerFast
)
import torch

# We need this to avoid a deadlock in the CPython/Torch C++ layer.
torch.__future__.set_swap_module_params_on_conversion(True)

# Load our tokenizer and our model.
tokenizer = PreTrainedTokenizerFast(
    tokenizer_file="model/tokenizer.json",
    clean_up_tokenization_spaces=False,    # Silences a warning.
)
model = AutoModelForSequenceClassification.from_pretrained("model/")

# Defer creating our inference pipeline so the caller can pick a device type.
_sentiment = None
def get_pipeline(device="mps"):
    """
    Create a sentiment-analysis pipeline using the given device.
    """
    global _sentiment
    if not _sentiment:
        _sentiment = pipeline(
            "sentiment-analysis",
            model=model,
            tokenizer=tokenizer,
            device=device,
        )
    return _sentiment
