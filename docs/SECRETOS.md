# Secretos y datos privados

La decisión para esta versión es **no almacenar secretos en este repositorio**. Las claves SSH privadas, `~/.netrc`, tokens de GitHub y perfiles de navegador deben permanecer en un backup cifrado externo, gestor de contraseñas o mecanismo de sincronización que controles.

Antes de hacer `git add`, ejecuta `./scripts/capture.sh --scan`, lee `git status --short` y revisa cada archivo nuevo. El escaneo heurístico no detecta todos los secretos. `~/.config/gh/hosts.yml`, `~/.config/rclone/`, el perfil de Zen y llaveros GNOME son especialmente peligrosos.

Tras restaurar una clave SSH: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519` (ajusta el nombre). Comprueba que puedes autenticarte antes de eliminar tu backup. Si se publica una credencial por error, **revócala/rota de inmediato**; borrarla de un commit no elimina las copias que otros hayan descargado.
