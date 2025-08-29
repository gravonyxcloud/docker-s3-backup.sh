# 🐳 Docker Backup Manager

Script **100% automatizado e interativo** para backup e restauração de volumes do Docker, com suporte a:

- ☁️ **Amazon S3 / S3 compatível** (via `aws-cli`)
- 🔄 **Servidor remoto via SSH** (via `rsync`)

Inclui:
- 🔎 Detecção de dependências (docker, tar, flock, awscli, rsync…)
- ⚡ Pergunta antes de instalar pacotes automaticamente
- 🔐 Geração e validação de checksums (`sha256sum`)
- 📦 Backup completo ou por volume específico
- 🔄 Restauração interativa de backups
- 📜 Listagem de backups já existentes

---

## 🚀 Instalação

Basta rodar:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/gravonyxcloud/docker-backup-manager/main/backup.sh](https://raw.githubusercontent.com/gravonyxcloud/docker-s3-backup.sh/refs/heads/main/docker-s3-backup.sh)
