#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$HOME/.docker-s3-backup.conf"
BACKUP_DIR="$HOME/docker_backups"
AWS_BIN="/usr/local/bin/aws"

# Função para instalar dependências
install_deps() {
  for cmd in docker tar flock sha256sum; do
    if ! command -v $cmd >/dev/null 2>&1; then
      echo "⚠️ Dependência '$cmd' não encontrada. Instale manualmente."
      exit 1
    fi
  done

  if ! command -v $AWS_BIN >/dev/null 2>&1; then
    echo "⚠️ Dependência 'awscli' não encontrada."
    read -p "Deseja instalar AWS CLI v2? (y/n): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
      unzip -qo /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install -i /usr/local/aws -b /usr/local/bin
      rm -rf /tmp/aws /tmp/awscliv2.zip
      echo "✅ AWS CLI instalado em $AWS_BIN"
    else
      echo "❌ Não é possível continuar sem AWS CLI."
      exit 1
    fi
  fi
}

# Função para salvar configuração
save_config() {
  mkdir -p "$BACKUP_DIR"
  cat > "$CONFIG_FILE" <<EOF
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
EOF
  chmod 600 "$CONFIG_FILE"
}

# Função para carregar configuração
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  else
    configure
  fi
}

# Função de configuração inicial
configure() {
  echo "=== Configuração do destino S3 ==="
  read -p "Bucket S3: " S3_BUCKET
  read -p "Prefixo (pasta) no bucket: " S3_PREFIX
  read -p "AWS Access Key: " AWS_ACCESS_KEY_ID
  read -p "AWS Secret Key: " AWS_SECRET_ACCESS_KEY
  read -p "AWS Region [us-east-1]: " AWS_DEFAULT_REGION
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
  save_config
  echo "✅ Configuração salva em $CONFIG_FILE"
}

# Backup de todos os volumes
backup_all() {
  load_config
  for vol in $(docker volume ls -q); do
    backup_volume "$vol"
  done
}

# Backup de volume específico
backup_volume() {
  load_config
  local VOL="$1"
  local TS
  TS=$(date +%Y%m%d-%H%M%S)
  local FILE="$BACKUP_DIR/${VOL}_${TS}.tar.gz"

  echo "📦 Fazendo backup do volume $VOL..."
  docker run --rm -v "$VOL":/data -v "$BACKUP_DIR":/backup alpine \
    tar czf "/backup/${VOL}_${TS}.tar.gz" -C /data .

  sha256sum "$FILE" > "$FILE.sha256"
  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION $AWS_BIN s3 cp "$FILE" "s3://$S3_BUCKET/$S3_PREFIX/"
  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION $AWS_BIN s3 cp "$FILE.sha256" "s3://$S3_BUCKET/$S3_PREFIX/"

  echo "✅ Backup concluído: $FILE"
}

# Restaurar volume
restore_volume() {
  load_config
  read -p "Nome do volume: " VOL
  read -p "Timestamp (ex: 20240902-120000): " TS
  local FILE="$BACKUP_DIR/${VOL}_${TS}.tar.gz"

  echo "⬇️ Baixando backup do S3..."
  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION $AWS_BIN s3 cp "s3://$S3_BUCKET/$S3_PREFIX/${VOL}_${TS}.tar.gz" "$FILE"

  docker volume create "$VOL" >/dev/null 2>&1 || true
  docker run --rm -v "$VOL":/data -v "$BACKUP_DIR":/backup alpine \
    sh -c "cd /data && tar xzf /backup/${VOL}_${TS}.tar.gz"
  echo "✅ Volume $VOL restaurado."
}

# Listar backups no S3
list_backups() {
  load_config
  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION $AWS_BIN s3 ls "s3://$S3_BUCKET/$S3_PREFIX/"
}

# Menu interativo
menu() {
  while true; do
    clear
    echo "=========================================="
    echo "     Docker Backup & Restore - v1.0"
    echo "=========================================="
    echo "[1] Configurar destino"
    echo "[2] Backup de todos os volumes"
    echo "[3] Backup de volume específico"
    echo "[4] Restaurar volume"
    echo "[5] Listar backups"
    echo "[0] Sair"
    echo "------------------------------------------"
    read -p "Escolha uma opção: " OP
    case "$OP" in
      1) configure ;;
      2) backup_all ;;
      3) read -p "Nome do volume: " VOL; backup_volume "$VOL" ;;
      4) restore_volume ;;
      5) list_backups ;;
      0) exit 0 ;;
      *) echo "❌ Opção inválida"; sleep 1 ;;
    esac
    read -p "Pressione ENTER para continuar..."
  done
}

### Execução principal ###
install_deps
load_config
menu
