#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$HOME/.docker-s3-backup.conf"
AWS_BIN="/usr/local/bin/aws"

banner() {
cat <<'EOF'
██████╗  ██████╗  ██████╗██╗  ██╗███████╗██████╗ 
██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗
██████╔╝██║   ██║██║     █████╔╝ █████╗  ██████╔╝
██╔═══╝ ██║   ██║██║     ██╔═██╗ ██╔══╝  ██╔═══╝ 
██║     ╚██████╔╝╚██████╗██║  ██╗███████╗██║     
╚═╝      ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝     
                                                 
EOF
echo "🚀 Docker Volume Backup para S3"
echo "====================================="
}

# Função para instalar dependências
install_deps() {
  for cmd in docker tar flock sha256sum; do
    if ! command -v $cmd >/dev/null 2>&1; then
      echo "⚠️ Dependência '$cmd' não encontrada. Instale manualmente."
      exit 1
    fi
  done

  if ! command -v unzip >/dev/null 2>&1; then
    echo "📦 Instalando unzip..."
    if command -v apt >/dev/null 2>&1; then
      apt update -y && apt install -y unzip
    elif command -v yum >/dev/null 2>&1; then
      yum install -y unzip
    else
      echo "❌ Não foi possível instalar unzip automaticamente."
      exit 1
    fi
  fi

  if ! command -v $AWS_BIN >/dev/null 2>&1; then
    echo "⚠️ AWS CLI não encontrada. Instalando..."
    curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -qo /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install -i /usr/local/aws -b /usr/local/bin
    rm -rf /tmp/aws /tmp/awscliv2.zip
    echo "✅ AWS CLI instalada em $AWS_BIN"
  fi
}

# Configuração inicial
setup_config() {
  echo "🔧 Configuração do destino S3"
  read -rp "Bucket S3: " S3_BUCKET
  read -rp "Região AWS: " AWS_REGION
  read -rp "Access Key ID: " AWS_ACCESS_KEY_ID
  read -rp "Secret Access Key: " AWS_SECRET_ACCESS_KEY

  cat > "$CONFIG_FILE" <<EOF
S3_BUCKET=$S3_BUCKET
AWS_REGION=$AWS_REGION
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
EOF

  echo "✅ Configuração salva em $CONFIG_FILE"
}

# Carregar config
load_config() {
  if [[ ! -f $CONFIG_FILE ]]; then
    setup_config
  fi
  source "$CONFIG_FILE"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
}

# Backup de volume
backup_volume() {
  local VOL=$1
  local TS=$(date +"%Y%m%d-%H%M%S")
  local FILE="/tmp/${VOL}_${TS}.tar.gz"

  echo "📦 Criando backup de $VOL..."
  docker run --rm -v "$VOL":/volume -v /tmp:/backup alpine \
    sh -c "cd /volume && tar czf /backup/${VOL}_${TS}.tar.gz ."

  echo "⬆️ Enviando para S3..."
  $AWS_BIN s3 cp "$FILE" "s3://$S3_BUCKET/$VOL/$VOL-$TS.tar.gz"

  rm -f "$FILE"
  echo "✅ Backup de $VOL concluído!"
}

# Restaurar volume
restore_volume() {
  local VOL=$1
  local TS=$2
  local FILE="/tmp/${VOL}_${TS}.tar.gz"

  echo "⬇️ Baixando backup do S3..."
  $AWS_BIN s3 cp "s3://$S3_BUCKET/$VOL/$VOL-$TS.tar.gz" "$FILE"

  echo "📂 Restaurando volume $VOL..."
  docker volume create "$VOL" >/dev/null 2>&1 || true
  docker run --rm -v "$VOL":/volume -v /tmp:/backup alpine \
    sh -c "cd /volume && tar xzf /backup/${VOL}_${TS}.tar.gz"

  rm -f "$FILE"
  echo "✅ Volume $VOL restaurado!"
}

# Menu interativo
menu() {
  echo ""
  echo "[1] Backup de TODOS volumes"
  echo "[2] Backup de um volume específico"
  echo "[3] Restaurar um volume"
  echo "[4] Reconfigurar destino S3"
  echo "[0] Sair"
  echo ""
  read -rp "Escolha uma opção: " OPT

  case $OPT in
    1)
      for v in $(docker volume ls -q); do
        backup_volume "$v"
      done
      ;;
    2)
      docker volume ls
      read -rp "Nome do volume: " VOL
      backup_volume "$VOL"
      ;;
    3)
      read -rp "Nome do volume: " VOL
      read -rp "Timestamp (ex: 20240901-123456): " TS
      restore_volume "$VOL" "$TS"
      ;;
    4)
      setup_config
      ;;
    0)
      exit 0
      ;;
    *)
      echo "❌ Opção inválida."
      ;;
  esac
}

### Fluxo principal
banner
install_deps
load_config
menu
