# Cohere Transcribe sur iPhone ?

Réponse courte : **oui, c'est faisable.** Le port Swift existe déjà, mais
le checkpoint mixte 2/3/4 bits qu'on utilise sur Mac demande un petit patch
côté Swift. Rien n'a encore été mesuré sur un vrai iPhone : les latences
ci-dessous sont des estimations.

## Le modèle

- Environ 2 milliards de paramètres : encodeur Conformer de 48 couches (largeur 1280),
  décodeur Transformer de 8 couches, vocabulaire SentencePiece de 16 384 tokens, fenêtres
  de 35 s.
- 14 langues (dont FR et EN), sans détection automatique : il faut indiquer la langue.
- Licence Apache 2.0 pour l'original CohereLabs : on peut l'embarquer en gardant la notice.
- Tailles : BF16 d'environ 3,9 GB ; build MLX mixte MarkChen d'environ 800 MB (un seul
  `model.safetensors`). Sur M2, le pic mesuré est de 0,95 GB de mémoire MLX.

## Moyens de le faire tourner

| Voie | État | Remarques |
| --- | --- | --- |
| **MLX Swift (GPU)** | `Blaizzy/mlx-audio-swift` contient déjà `MLXAudioSTT/Models/CohereTranscribe` (environ 2 150 lignes : encodeur, décodeur, tokenizer, streaming, VAD). iOS 17+ | Le checkpoint MarkChen a `codex_pointwise_linearized: true` : les pointwise 1×1 sont des `Linear` quantifiés, alors que le port les déclare en `Conv1d`. Il faut un patch d'environ 30 à 50 lignes (plus le cast du patch Python). |
| `soniqo/speech-swift` | Cohere en MLX natif, INT5 de 1,6 GiB (environ 2,6 GB de mémoire), iOS 18+ | Plus lourd que le checkpoint 2/3/4 bits. |
| **Core ML / ANE** | `FluidInference/cohere-transcribe-03-2026-coreml` (FluidAudio) : encodeur INT8 de 1,8 GB, décodeur FP16 | Mesuré sur M2 : seulement 1,7 à 1,9× le temps réel, et 3 à 6 min de compilation ANE au premier lancement. |
| ONNX / ggml | Export hybride Core ML + ONNX ; pas de port ggml | – |

## Mémoire et appareils

- 8 GB de RAM : iPhone 15 Pro, 16, 16 Pro, 17. 12 GB : 17 Pro / Pro Max. 6 GB : iPhone 15,
  14, 13 Pro.
- Sans entitlement, une app est tuée (jetsam) vers 50 à 60 % de la RAM. L'entitlement
  `com.apple.developer.kernel.increased-memory-limit` relève ce plafond.
- Avec environ 1 GB de pic, un appareil de 8 GB passe largement, et un de 6 GB passe
  probablement avec l'entitlement.
- Latence estimée : le GPU A17 Pro / A18 Pro est environ 1,5 à 2,5× plus lent qu'un M2.
  Compter environ 8 à 15× le temps réel, soit 2 à 5 s par minute d'audio, avec du
  throttling thermique sur les longues sessions. Le découpage VAD de Murmure
  (`MurmureCore/Chunker`) cache l'essentiel de cette latence.

## Alternatives (FR + EN)

- **SpeechAnalyzer / SpeechTranscriber (iOS 26)** : rien à télécharger et mémoire hors du
  process, mais précision inférieure à Cohere. C'est le meilleur repli.
- **WhisperKit** : mature sur ANE, mais plus lourd.
- **Parakeet v3 (FluidAudio)** : très rapide et en streaming, mais un cran en dessous en FR.

## Plan recommandé

1. Cible iOS 17+, `mlx-audio-swift` (produit `MLXAudioSTT`), entitlement Increased Memory
   Limit.
2. Patcher `CohereTranscribeEncoder.swift` : `Linear` à la place de `Conv1d` quand le flag
   est présent, et le cast des features. Proposer ce patch en PR upstream.
3. Télécharger les environ 800 MB au premier lancement plutôt que de les mettre dans le
   bundle.
4. Réutiliser `MurmureCore` tel quel : `Chunker`, `Wav`, `HotkeyState` et `Language` n'ont
   aucune dépendance macOS.
5. Mesurer sur iPhone 15 Pro et 16 : RTF, pic `phys_footprint`, thermique. Garder
   SpeechAnalyzer en repli pour les appareils de 6 GB ou moins.

Bonus : cette même voie Swift permettrait de supprimer Python sur Mac, avec
voiced réécrit en service natif (XPC ou socket) autour de `MLXAudioSTT`.

Sources : [modèle CohereLabs](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026),
[build MLX MarkChen](https://huggingface.co/MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit),
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) ([#134](https://github.com/Blaizzy/mlx-audio-swift/issues/134)),
[speech-swift](https://github.com/soniqo/speech-swift),
[FluidAudio Cohere](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md),
[MLX sur iPhone](https://gist.github.com/awni/fe4f96c21ead68e60191190cbc1c129b),
[entitlements mémoire](https://zenn.dev/mtfum/articles/ios_memory_entitlements?locale=en).
