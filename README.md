# Murmure

Dictée vocale locale pour macOS. Appuie sur **Fn + ⇧ droit**, parle, et le texte
est collé dans l'app active. Tout tourne sur ton Mac : l'audio ne sort jamais.

<p align="center">
  <img src="docs/img/pill-speaking.png" width="232" alt="Pastille d'enregistrement"><br><br>
  <img src="docs/img/settings.png" width="420" alt="Réglages">
</p>

- **Appui bref** : démarre, un second appui transcrit et colle. **Maintenu** : push-to-talk.
- **Entrée** valide, **Esc** annule. Le raccourci et la langue se changent dans les réglages.

## Modèle

[Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)
(environ 2 milliards de paramètres, 14 langues), dans sa version quantifiée
[MLX 2/3/4 bits](https://huggingface.co/MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit)
qui tourne sur le GPU des Mac Apple Silicon : environ 800 MB sur disque et 1 GB
en mémoire. Un petit service local (`voiced`) le garde chargé une seule fois,
en commun avec [Orb](https://github.com/Th0rgal/sandboxed.sh). Il le libère
après 10 minutes d'inactivité.

## Build et installation

Il faut un Mac Apple Silicon sous macOS 14 ou plus récent, Xcode 16 et Python 3.10 à 3.13.

```sh
git clone https://github.com/Th0rgal/murmure && cd murmure
scripts/install-voiced.sh --download-model   # service de transcription + modèle
scripts/build-app.sh --install               # compile, signe et copie dans /Applications
```

Au premier lancement, autorise **Accessibilité** et **Micro**. Si Fn ouvre les
emojis, règle *Clavier › « Appuyer sur 🌐 pour »* sur *Ne rien faire*.
