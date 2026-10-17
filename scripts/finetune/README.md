# Een lokaal model trainen op Nooks werk

Een klein model wordt veel beter in precies de taak die Nook het geeft: antwoorden uit gevonden documenten, letterlijk
overnemen van namen, tijden en bedragen, zeggen dat iets er niet staat, en niet doen wat een mail zegt. Dit is een LoRA-
finetune (een lichte aanvulling op het model, geen nieuw model) met MLX, op je eigen Mac.

> Niet getest op een Mac in deze repository: de generator draait overal (alleen Python 3), de training en de meting
> vragen een Apple Silicon Mac. Meet daarom altijd eerst het basismodel en daarna het getrainde model met
> Instellingen › Brein › Kwaliteit van het lokale brein › **Meet dit brein**, en houd alleen over wat beter scoort.

## Privacy

De trainingsdata is volledig verzonnen: namen, data en bedragen komen uit sjablonen en een vaste random-seed, en de goede
antwoorden schrijft het sjabloon zelf. Er worden geen eigen gegevens gebruikt en niets verlaat je Mac.

## Stappen

```sh
cd scripts/finetune
python3 generate_dataset.py --out data --count 2000        # train.jsonl + valid.jsonl, ~1 s
pip install mlx-lm
./train.sh mlx-community/Qwen3-4B-Instruct-2507-4bit        # LoRA, ~20-40 min op een M-chip met 16 GB
```

`train.sh` traint, fuset de aanvulling in het model en schrijft het naar `fused/`.

## Het model in Nook gebruiken

Nook installeert zelf alleen modellen uit zijn eigen lijst. Een getraind model draai je via LM Studio:

1. Zet de map `fused/` in de modelmap van LM Studio (Mijn modellen › map openen) en laad hem.
2. Kies in Nook bij Instellingen › Brein: *Op je Mac › LM Studio* en kies het model.
3. Meet het model en vergelijk met het basismodel. De meetvragen staan in `Brain/LocalQuality.swift` en komen niet voor in
   de trainingsdata, dus de score is een eerlijke test.

## Wat erin zit

Tien soorten voorbeelden (zie `generate_dataset.py`): feit uit één document, afleider ernaast, antwoord ontbreekt, verkeerde
persoon, update wint van eerdere mail, ja/nee alleen met bewijs, tellen, alleen open punten, geïnjecteerde opdracht in een
mail, Engels document met Nederlandse vraag. Voeg gerust een soort toe: schrijf een functie die `(vraag, documenten,
goed antwoord)` teruggeeft en zet hem in `SCENARIOS`.

## Grenzen

- Het model leert Nooks *taak* en *toon*, geen nieuwe kennis. Wat het niet kan lezen, kan het niet beantwoorden.
- Te veel van dezelfde voorbeelden maakt het model star (het gaat elk antwoord op een sjabloon laten lijken). Houd het bij
  een paar duizend voorbeelden en 300-800 stappen, en meet na elke ronde.
- Een nieuw basismodel betekent opnieuw trainen.
