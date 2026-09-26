# Orb ↔ voiced

`orb-shared-voiced.patch` s'applique sur la branche de
[sandboxed.sh#909](https://github.com/Th0rgal/sandboxed.sh/pull/909)
(`orb/src-tauri/src/voice.rs`, base `e03f344`) :

```sh
cd sandboxed.sh && git apply ../murmure/integrations/orb/orb-shared-voiced.patch
```

Effet :

- Avant de lancer son worker privé, Orb tente de se connecter à
  `~/Library/Application Support/md.thomas.voice/voiced.sock` (surchargeable
  avec `ORB_VOICE_SOCKET`, désactivable avec `ORB_VOICE_SOCKET=off`). Si la
  connexion réussit, il parle le même protocole v1 sur le socket. Orb et
  Murmure partagent alors **un seul modèle**.
- Si le socket n'existe pas ou ne répond pas, Orb garde exactement le
  comportement de la PR (worker privé sur stdio).
- En mode partagé :
  - « Annuler » ferme la connexion au lieu de tuer un process. Le démon
    continue et le résultat est jeté.
  - Le reaper d'inactivité ferme la connexion ; c'est voiced qui décharge le
    modèle.
  - `worker_pid()` renvoie le pid du démon (fourni par `hello`), pour que les
    métriques machine attribuent sa mémoire au bon process.
- Côté Rust, `Worker` passe d'un `Child` à `Handle::{Child, Shared}`, et
  stdin/stdout deviennent des `Box<dyn Read/Write>`. Le frontend n'est pas
  modifié.

Vérifié sur la branche (Mac M2) :

```sh
cargo test voice    # 13 passed, dont shared_daemon_is_preferred_over_a_private_worker
cargo clippy --all-targets   # aucun nouvel avertissement dans voice.rs
```
