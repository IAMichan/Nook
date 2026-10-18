#!/bin/sh
# LoRA-training op de data van generate_dataset.py, daarna samenvoegen tot een model dat LM Studio kan laden.
# Gebruik: ./train.sh [basismodel] [stappen]
set -eu
MODEL="${1:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
ITERS="${2:-600}"
cd "$(dirname "$0")"
[ -f data/train.jsonl ] || python3 generate_dataset.py --out data
python3 -m mlx_lm.lora --model "$MODEL" --train --data data --iters "$ITERS" --batch-size 2 --num-layers 16 --adapter-path adapters
python3 -m mlx_lm.fuse --model "$MODEL" --adapter-path adapters --save-path fused
echo "Klaar: $(pwd)/fused. Laad dit model in LM Studio en meet het in Nook (Instellingen > Brein)."
