#!/usr/bin/env bash
# docker-s3-backup.sh
# Backup e Restore de volumes Docker para S3 ou servidor remoto via rsync
# Author: Biel + ChatGPT
# License: MIT

set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="${HOME}/.docker-s3-backup.conf"
WORKDIR="${HOME}/.docker-s3-backup"
TMPDIR="${WORKDIR}/tmp"
LOGFILE="${WORKDIR}/backup.log"
LOCKFILE="/var/lock/docker-s3-backup.lock"

# ---------------- Utils ----------------
timestamp() { date +"%Y%m%dT%H%M%S"; }
log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOGFILE"; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else echo ""; fi
}

ensure_dep() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "⚠️  Dependência '$bin' não encontrada."

    if [[ "$bin" == "aws" ]]; then
        read -rp "Deseja instalar AWS CLI v2 oficial? (y/n): " ans
        if [[ "$ans" == "y" ]]; then
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
            unzip -o /tmp/awscliv2.zip -d /tmp
            sudo /tmp/aws/install
            rm -rf /tmp/aws /tmp/awscliv2.zip
        else
            echo "❌ AWS CLI é obrigatório para modo S3"; exit 1
        fi
    else
        local pm; pm=$(detect_pkg_manager)
        if [[ -n "$pm" ]]; then
          read -rp "Deseja instalar '$pkg'? (y/n): " ans
          if [[ "$ans" == "y" ]]; then
            if [[ "$pm" == "apt" ]]; then
              sudo apt-get update && sudo apt-get install -y "$pkg" unzip curl
            else
              sudo "$pm" install -y "$pkg" unzip curl
            fi
          else
            echo "❌ Não posso continuar sem '$bin'."; exit 1
          fi
        else
          echo "❌ Não reconheço gerenciador de pacotes."; exit 1
        fi
    fi
  fi
}

ensure_dirs() {
  mkdir -p "$WORKDIR" "$TMPDIR"
  touch "$LOGFILE"
}

# ---------------- Config ----------------
declare -A cfg
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "$k" ]] && continue
      cfg["$k"]="${v}"
    done < <(sed -E '/^\s*#/d;/^\s*$/d' "$CONFIG_FILE")
  fi
  cfg["UPLOAD_MODE"]="${cfg["UPLOAD_MODE"]:-aws}"
  cfg["S3_BUCKET"]="${cfg["S3_BUCKET"]:-}"
  cfg["S3_REGION"]="${cfg["S3_REGION"]:-us-east-1}"
  cfg["LOCAL_RETENTION"]="${cfg["LOCAL_RETENTION"]:-3}"
  cfg["RSYNC_USER"]="${cfg["RSYNC_USER"]:-}"
  cfg["RSYNC_HOST"]="${cfg["RSYNC_HOST"]:-}"
  cfg["RSYNC_PATH"]="${cfg["RSYNC_PATH"]:-/backups}"
}

save_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
UPLOAD_MODE=${cfg["UPLOAD_MODE"]}
S3_BUCKET=${cfg["S3_BUCKET"]}
S3_REGION=${cfg["S3_REGION"]}
LOCAL_RETENTION=${cfg["LOCAL_RETENTION"]}
RSYNC_USER=${cfg["RSYNC_USER"]}
RSYNC_HOST=${cfg["RSYNC_HOST"]}
RSYNC_PATH=${cfg["RSYNC_PATH"]}
EOF
  chmod 600 "$CONFIG_FILE"
  log "Config salva em $CONFIG_FILE"
}

# ---------------- Upload ----------------
aws_upload() {
  local src="$1" dest="$2"
  aws s3 cp "$src" "$dest" --region "${cfg["S3_REGION"]}"
}

rsync_upload() {
  local src="$1"
  local dest="${cfg["RSYNC_USER"]}@${cfg["RSYNC_HOST"]}:${cfg["RSYNC_PATH"]}/$(basename "$src")"
  rsync -avz "$src" "$dest"
}

do_upload() {
  local src="$1" dest="$2"
  if [[ "${cfg["UPLOAD_MODE"]}" == "aws" ]]; then
    aws_upload "$src" "$dest"
  else
    rsync_upload "$src"
  fi
}

# ---------------- Backup ----------------
list_volumes() {
  docker volume ls --format '{{.Name}}'
}

backup_volume() {
  local volume="$1"
  local ts filename local_archive sha_file
  ts="$(timestamp)"
  filename="${volume}_${ts}.tar.gz"
  local_archive="${WORKDIR}/${filename}"
  sha_file="${local_archive}.sha256"

  log "📦 Backup volume $volume"
  docker run --rm -v "${volume}:/data:ro" alpine sh -c "cd /data && tar czf - ." > "$local_archive"
  sha256sum "$local_archive" | awk '{print $1}' > "$sha_file"

  do_upload "$local_archive" "$filename"
  do_upload "$sha_file" "$filename.sha256"

  log "✅ Backup finalizado $filename"
}

cmd_backup_all() {
  for v in $(list_volumes); do
    backup_volume "$v"
  done
}

# ---------------- Restore ----------------
cmd_restore() {
  local volume="$1" stamp="$2"
  if [[ -z "$volume" || -z "$stamp" ]]; then
    echo "Uso: restore <volume> <timestamp>"; exit 1
  fi
  local filename="${volume}_${stamp}.tar.gz"
  local tmp_dl="${TMPDIR}/${filename}"

  if [[ "${cfg["UPLOAD_MODE"]}" == "aws" ]]; then
    aws s3 cp "s3://${cfg["S3_BUCKET"]}/${volume}/${filename}" "$tmp_dl" --region "${cfg["S3_REGION"]}"
  else
    rsync "${cfg["RSYNC_USER"]}@${cfg["RSYNC_HOST"]}:${cfg["RSYNC_PATH"]}/${filename}" "$tmp_dl"
  fi

  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume"
  docker run --rm -i -v "${volume}:/data" alpine sh -c "cd /data && tar xz" < "$tmp_dl"
  log "♻️  Restore concluído para volume $volume"
}

# ---------------- Config interactive ----------------
cmd_config() {
  load_config
  echo "=== Configuração ==="
  read -rp "Método de upload (aws|rsync) [${cfg["UPLOAD_MODE"]}]: " in
  [[ -n "$in" ]] && cfg["UPLOAD_MODE"]="$in"
  if [[ "${cfg["UPLOAD_MODE"]}" == "aws" ]]; then
    read -rp "S3 Bucket [${cfg["S3_BUCKET"]}]: " in
    [[ -n "$in" ]] && cfg["S3_BUCKET"]="$in"
    read -rp "S3 Região [${cfg["S3_REGION"]}]: " in
    [[ -n "$in" ]] && cfg["S3_REGION"]="$in"
  else
    read -rp "Usuário SSH [${cfg["RSYNC_USER"]}]: " in
    [[ -n "$in" ]] && cfg["RSYNC_USER"]="$in"
    read -rp "Host SSH [${cfg["RSYNC_HOST"]}]: " in
    [[ -n "$in" ]] && cfg["RSYNC_HOST"]="$in"
    read -rp "Diretório remoto [${cfg["RSYNC_PATH"]}]: " in
    [[ -n "$in" ]] && cfg["RSYNC_PATH"]="$in"
  fi
  save_config
}

# ---------------- CLI ----------------
cmd_help() {
cat <<EOF
Uso: $0 <comando>

Comandos:
  config       - configurar destino de backup
  backup       - backup de todos volumes Docker
  backup <vol> - backup de um volume específico
  restore VOL TIMESTAMP - restaurar volume
  help         - mostrar ajuda
EOF
}

main() {
  ensure_dirs
  load_config
  ensure_dep docker docker.io
  ensure_dep tar tar
  ensure_dep flock util-linux
  ensure_dep sha256sum coreutils
  if [[ "${cfg["UPLOAD_MODE"]}" == "aws" ]]; then
    ensure_dep aws awscli
  else
    ensure_dep rsync rsync
  fi

  case "${1:-help}" in
    config) cmd_config ;;
    backup)
      if [[ -n "${2:-}" ]]; then backup_volume "$2"; else cmd_backup_all; fi ;;
    restore) shift; cmd_restore "$@" ;;
    help|*) cmd_help ;;
  esac
}

main "$@"
