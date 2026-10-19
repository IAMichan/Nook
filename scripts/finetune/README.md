# Fine-Tuning a Local Model for Nook

Small local models become significantly better at Nook's exact workflow—answering strictly from retrieved documents, copying names, times, and amounts verbatim, stating clearly when information is missing, and ignoring prompt-injection attempts inside emails—with a lightweight LoRA fine-tune using MLX on your Mac.

> **Tip:** Always benchmark the base model first and compare it against your fine-tuned model using **Settings › Brain › Local Brain Quality › Evaluate this brain**, keeping only adapters that measurably improve accuracy.

## Privacy

The training dataset is 100% synthetic: names, dates, and amounts are generated from templates with a fixed random seed, and ground-truth answers are produced deterministically by the generator. None of your personal data is used and nothing leaves your Mac.

## Quick Start

```sh
cd scripts/finetune
python3 generate_dataset.py --out data --count 2000        # Generates train.jsonl + valid.jsonl in ~1 s
pip install mlx-lm
./train.sh mlx-community/Qwen3-4B-Instruct-2507-4bit       # Runs LoRA fine-tune (~20-40 min on a 16 GB Apple Silicon Mac)
```

`train.sh` trains the LoRA adapter, fuses it into the base model, and writes the result to `fused/`.

## Using the Fine-Tuned Model in Nook

You can serve your fused model locally via LM Studio:

1. Move or symlink the `fused/` directory into LM Studio's models folder (*My Models › Open folder*) and load it.
2. In Nook, go to **Settings › Brain**, choose **On Your Mac › LM Studio**, and select the model.
3. Run **Evaluate this brain** to compare against the base model. The 20 benchmark questions in `Brain/LocalQuality.swift` are held out from the synthetic training templates, ensuring an honest evaluation.

## Included Training Scenarios

`generate_dataset.py` covers ten scenario types: single-document fact extraction, distractor document alongside the answer, missing answer ("not found in sources"), wrong person disambiguation, newer email superseding an older one, evidence-backed yes/no, counting items, open-only items, prompt-injection resistance inside untrusted email bodies, and cross-lingual retrieval.

## Limitations

- Fine-tuning teaches Nook's *grounding discipline and response style*, not new world knowledge.
- Avoid over-training (stick to a few thousand examples and 300–800 iterations) so the model does not become overly rigid, and re-run the evaluation benchmark after each run.
