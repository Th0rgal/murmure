# Architecture

## Objectifs

1. Un seul modèle résident par Mac, quel que soit le nombre de clients (Murmure, Orb, un script).
2. Une latence perçue minimale, y compris sur les longues dictées.
3. Aucune mémoire occupée quand on ne dicte pas.
4. Zéro réseau : l'audio ne quitte jamais la machine.

## Composants

### `voiced/` : le démon partagé (Python + MLX)

- `worker.py` et `mlx_audio_cohere_quant_patch.py` sont **copiés à l'identique** depuis
  `orb/voice/` de sandboxed.sh (PR #909, commit `e03f344`). Mêmes pins : modèle
  `MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit@553445e`, mlx-audio `77a6cfc`.
- `voiced.py` réutilise `Worker`, `read_request` et `write_response` pour servir le **même
  protocole v1** sur un socket Unix, avec une connexion par client.
  - Un **seul thread d'inférence** possède le backend MLX. Les threads de connexion
    décodent les trames puis passent les jobs par une queue. L'inférence est donc
    sérialisée entre clients, et MLX n'est jamais utilisé depuis deux threads.
  - `shutdown` ne ferme que la connexion du client qui l'envoie. `unload` est indicatif :
    c'est voiced qui gère la résidence du modèle.
  - Si un client se déconnecte en cours de requête (par exemple l'annulation dans Orb), le
    démon ne s'arrête pas : le résultat est simplement jeté.
  - Mémoire : le modèle est déchargé après `VOICED_UNLOAD_SECS` (600 s) sans requête. Le
    process s'arrête après `VOICED_EXIT_SECS` (1800 s) sans client.
- `md.thomas.voiced.plist.in` est un LaunchAgent **activé par socket**. launchd possède
  `voiced.sock` (mode 0600) et démarre voiced à la première connexion. Les clients n'ont
  donc jamais à gérer le cycle de vie du démon. `launch_activate_socket` est appelé via
  ctypes. Lancé à la main, voiced crée lui-même le socket.
- `scripts/install-voiced.sh` réutilise le venv d'Orb
  (`~/Library/Application Support/Orb/voice/.venv`) s'il existe, pour ne pas dupliquer
  environ 1 GB de dépendances. Sinon, `--own-venv` crée un venv dédié.

Protocole (identique à Orb) : une ligne JSON par requête, suivie de `audio_bytes` octets
WAV pour `transcribe`, et une ligne JSON par réponse. `hello` ajoute
`{"shared": true, "daemon": "voiced", "clients": n, "pid": …, "loaded": …}`.

### `Sources/MurmureCore` : logique testable

- `HotkeyState` gère l'accord Fn + ⇧ droit. Un tap bascule l'enregistrement ; un maintien
  de plus de 0,35 s fait du push-to-talk.
- `Chunker` est une VAD par énergie sur des trames de 30 ms, avec un seuil adaptatif :
  3 × le 10e percentile, plafonné à 30 % du 90e percentile, sur les 10 dernières secondes.
  Il coupe au milieu d'une pause d'au moins 450 ms une fois 7 s accumulées, et force la
  coupe sur la trame la plus calme avant 28 s.
- `VoiceClient` est le client POSIX du socket (timeouts via `SO_RCVTIMEO`, reconnexion
  unique si le démon a été relancé).
- `Wav` encode en PCM 16 bits mono 16 kHz.

### `Sources/Murmure` : l'app

- `HotkeyMonitor` : `CGEventTap` sur `flagsChanged` (keycodes 63 = Fn, 60 = ⇧ droit).
  Pendant une session, il avale Esc et Entrée. Il nécessite l'Accessibilité.
- `Recorder` : `AVAudioEngine`, puis `AVAudioConverter` vers 16 kHz mono float.
- `Dictation` : la machine à états de la session. Le préchargement est lancé au démarrage
  de la session. Chaque morceau VAD est envoyé sur une queue série (le client n'est pas
  thread-safe). À la validation, seule la fin de l'audio est envoyée, puis les morceaux
  sont assemblés dans l'ordre et collés. Un compteur de session jette les résultats d'une
  session annulée.
- `Overlay` : un `NSPanel` non activant (l'app cible garde le focus) contenant une
  pastille SwiftUI, avec des barres de niveau en direct et des points animés pendant la
  transcription.
- `Paster` : presse-papiers puis ⌘V, et restauration du presse-papiers précédent.

## Performances mesurées (M2, 16 GB)

| | |
| --- | --- |
| Chargement du modèle | 1,2 à 2,5 s (préchauffage à froid inclus : jusqu'à 10 s juste après le démarrage) |
| Transcription à chaud, extrait de démo de 5,4 s | 0,6 à 0,9 s |
| Mémoire MLX active / pic | 0,87 / 0,95 GB |
| Dictée de 60 s sans découpage (log Orb) | environ 10 s d'inférence après validation |
| Dictée de 60 s avec découpage | seule la dernière phrase reste à transcrire (environ 1 s) |

## Pistes

- **Swift pur, sans Python.** `Blaizzy/mlx-audio-swift` contient déjà un port Swift de
  Cohere Transcribe. Il faudrait l'adapter au checkpoint MarkChen (pointwise en `Linear`,
  voir `IPHONE.md`). Voiced pourrait alors devenir un XPC service natif.
- Streaming token par token (`generateStream` côté Swift) pour afficher le texte en direct.
