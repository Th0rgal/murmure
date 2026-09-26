# Murmure

Dictée locale ultra minimale pour macOS, dans l'esprit de Typeless.
**Fn + ⇧ droit** ouvre une petite pastille, tu parles, et le texte est collé
dans l'app active. Tout se passe sur le Mac, via [Cohere Transcribe] en MLX.
Le modèle est chargé **une seule fois** et partagé avec Orb.

<p align="center"><img src="docs/img/pill-speaking.png" width="205" alt="Pastille pendant l'enregistrement"></p>

| Geste | Effet |
| --- | --- |
| Tap **Fn + ⇧ droit** | démarre l'enregistrement ; un second tap transcrit et colle |
| Maintenir **Fn + ⇧ droit** | push-to-talk : relâcher transcrit et colle |
| **Entrée** ou ✓ | transcrit et colle |
| **Esc** ou ✕ | annule |
| Puce **FR** au-dessus de la pastille, ou menu ≋ | change la langue (14 langues, mémorisée) |

## Installation

Prérequis : Mac Apple Silicon, macOS 14 ou plus récent, Xcode 16 ou plus récent.

```sh
# 1. Le démon partagé (réutilise le venv voix d'Orb s'il existe).
scripts/install-voiced.sh --download-model

# 2. L'app, signée et copiée dans /Applications.
scripts/build-app.sh --install
```

Au premier lancement, autorise **Accessibilité** (raccourci global et collage)
et **Micro**. Si Fn seul ouvre les emojis ou la dictée Apple, règle
*Réglages › Clavier › « Appuyer sur 🌐 pour »* sur *Ne rien faire*.

## Architecture

```
 Murmure.app (Swift)                      Orb (Tauri, voice.rs)
 CGEventTap Fn+⇧R → pastille              bouton micro
 AVAudioEngine → 16 kHz → VAD             WebAudio → WAV
        │ découpe aux pauses                     │
        └──────────────┬─────────────────────────┘
                       ▼  protocole v1 (ligne JSON + octets WAV)
   ~/Library/Application Support/md.thomas.voice/voiced.sock   (0600, activée par launchd)
                       ▼
   voiced.py : une seule instance, un seul thread d'inférence, un seul modèle MLX (~0,95 GB)
   déchargé après 10 min d'inactivité, process terminé après 30 min ; launchd le relance à la connexion suivante
```

- **Pas de double chargement.** `voiced` parle exactement le protocole du
  worker d'Orb (`worker.py`, repris à l'identique depuis
  [sandboxed.sh#909]), mais sur un socket Unix au lieu de stdio. Orb s'y
  connecte s'il existe (voir [integrations/orb](integrations/orb)) et sinon
  lance son worker privé, comme avant.
- **Latence.** Pendant que tu parles, Murmure coupe l'audio aux pauses (après
  environ 7 s, au plus 28 s, ce qui tient dans la fenêtre de 35 s du modèle)
  et transcrit chaque morceau en tâche de fond. Quand tu valides, il ne reste
  que la dernière phrase à traiter, donc l'attente ne dépend plus de la durée
  de la dictée. Le modèle est préchargé dès l'appui sur le raccourci.
- **Collage.** Presse-papiers puis ⌘V synthétique. Le presse-papiers
  précédent est restauré, et l'entrée est marquée transitoire pour que les
  gestionnaires de presse-papiers l'ignorent.

Détails : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Développement

```sh
swift test                          # hotkey, VAD, WAV, langue, plus un test live contre voiced s'il est installé
python3 voiced/test_voiced.py -v    # démon avec un faux backend (multi-clients, un seul modèle, un seul thread)
swift run Murmure                   # lancement depuis le terminal (les permissions s'appliquent au terminal)
.build/debug/Murmure --render-pill docs/img   # capture la pastille en PNG
tail -f ~/Library/Application\ Support/md.thomas.voice/logs/voiced.log
log stream --predicate 'subsystem == "md.thomas.murmure"'
```

Identifiants : app `md.thomas.murmure`, démon `md.thomas.voiced`.

[Cohere Transcribe]: https://huggingface.co/MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit
[sandboxed.sh#909]: https://github.com/Th0rgal/sandboxed.sh/pull/909
