#!/bin/bash
set -euo pipefail

# ==========================================================
# Issabel 5 - Control Panel (control_panel) Installer FIXED
# Copyright David Oliveira  WhatsApp +55(16) 98170-3272
# ==========================================================

MODULES_DIR="/var/www/html/modules"
MODULE_NAME="control_panel"

REPO_URL="https://github.com/ISSABELPBX/panel-issabel5.git"
REPO_DIR="/usr/src/panel-issabel5"

ACL_DB="/var/www/db/acl.db"
MENU_DB="/var/www/db/menu.db"

ASTERISK_USER="asterisk"
ASTERISK_GROUP="asterisk"

# Grupo Administrator no seu ambiente
ADMIN_GROUP_ID="1"

log()  { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERRO]\033[0m $*" >&2; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Execute como root: sudo bash $0"
    exit 1
  fi
}

install_deps() {
  log "Instalando dependências (git, sqlite)..."
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install git sqlite || true
  else
    yum -y install git sqlite || true
  fi
}

validate_env() {
  log "Validando estrutura do Issabel 5..."
  [[ -d "$MODULES_DIR" ]] || { err "Não achei $MODULES_DIR"; exit 1; }
  [[ -f "$ACL_DB" ]]      || { err "Não achei $ACL_DB"; exit 1; }
  [[ -f "$MENU_DB" ]]     || { err "Não achei $MENU_DB"; exit 1; }
}

clone_repo() {
  log "Baixando/atualizando repositório do módulo..."
  mkdir -p /usr/src

  if [[ -d "$REPO_DIR/.git" ]]; then
    cd "$REPO_DIR"
    git pull
  else
    git clone "$REPO_URL" "$REPO_DIR"
  fi
}

install_module_files() {
  log "Instalando arquivos do módulo $MODULE_NAME..."

  if [[ ! -d "$REPO_DIR/$MODULE_NAME" ]]; then
    err "Pasta do módulo não encontrada: $REPO_DIR/$MODULE_NAME"
    exit 1
  fi

  # Backup se já existir
  if [[ -d "$MODULES_DIR/$MODULE_NAME" ]]; then
    BACKUP_DIR="${MODULES_DIR}/${MODULE_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
    warn "Módulo já existe. Criando backup em: $BACKUP_DIR"
    mv "$MODULES_DIR/$MODULE_NAME" "$BACKUP_DIR"
  fi

  cp -a "$REPO_DIR/$MODULE_NAME" "$MODULES_DIR/"

  chown -R "${ASTERISK_USER}:${ASTERISK_GROUP}" "$MODULES_DIR/$MODULE_NAME"
  find "$MODULES_DIR/$MODULE_NAME" -type d -exec chmod 755 {} \;
  find "$MODULES_DIR/$MODULE_NAME" -type f -exec chmod 644 {} \;

  [[ -f "$MODULES_DIR/$MODULE_NAME/index.php" ]] || warn "index.php não encontrado (estranho)."
  log "Arquivos instalados em $MODULES_DIR/$MODULE_NAME"
}

ensure_acl_resource() {
  log "Registrando resource em acl_resource..."

  local RID
  RID="$(sqlite3 "$ACL_DB" "SELECT id FROM acl_resource WHERE name='$MODULE_NAME' LIMIT 1;")"

  if [[ -n "$RID" ]]; then
    log "acl_resource já existe: id=$RID"
  else
    sqlite3 "$ACL_DB" "INSERT INTO acl_resource (name, description) VALUES ('$MODULE_NAME', 'Control Panel');"
    RID="$(sqlite3 "$ACL_DB" "SELECT id FROM acl_resource WHERE name='$MODULE_NAME' LIMIT 1;")"
    log "acl_resource criado: id=$RID"
  fi

  echo "$RID"
}

ensure_module_privileges() {
  local RID="$1"
  log "Criando privilégios do módulo em acl_module_privileges (access/view)..."

  # access
  sqlite3 "$ACL_DB" "INSERT OR IGNORE INTO acl_module_privileges (id_resource, privilege, desc_privilege)
                     VALUES ($RID, 'access', 'Access Control Panel');"

  # view
  sqlite3 "$ACL_DB" "INSERT OR IGNORE INTO acl_module_privileges (id_resource, privilege, desc_privilege)
                     VALUES ($RID, 'view', 'View Control Panel');"

  log "Privilégios criados (ou já existiam)."
}

ensure_group_permissions_for_privileges() {
  local RID="$1"

  log "Vinculando privilégios ao grupo administrator (id=$ADMIN_GROUP_ID)..."

  # pegar ids dos privileges
  local PID_ACCESS PID_VIEW
  PID_ACCESS="$(sqlite3 "$ACL_DB" "SELECT id FROM acl_module_privileges WHERE id_resource=$RID AND privilege='access' LIMIT 1;")"
  PID_VIEW="$(sqlite3 "$ACL_DB" "SELECT id FROM acl_module_privileges WHERE id_resource=$RID AND privilege='view' LIMIT 1;")"

  if [[ -z "$PID_ACCESS" || -z "$PID_VIEW" ]]; then
    err "Não consegui localizar privilege IDs (access/view)."
    exit 1
  fi

  sqlite3 "$ACL_DB" "INSERT OR IGNORE INTO acl_module_group_permissions (id_group, id_module_privilege)
                     VALUES ($ADMIN_GROUP_ID, $PID_ACCESS);"

  sqlite3 "$ACL_DB" "INSERT OR IGNORE INTO acl_module_group_permissions (id_group, id_module_privilege)
                     VALUES ($ADMIN_GROUP_ID, $PID_VIEW);"

  log "Grupo administrator liberado para access/view."
}

ensure_group_action_access() {
  local RID="$1"
  log "Garantindo acl_group_permission (action access) para administrator..."

  # action access no seu ambiente é 1
  sqlite3 "$ACL_DB" "INSERT OR IGNORE INTO acl_group_permission (id_action, id_group, id_resource)
                     VALUES (1, $ADMIN_GROUP_ID, $RID);"

  log "acl_group_permission OK."
}

ensure_menu_entry() {
  log "Registrando menu no menu.db (pbxconfig -> Issabel Panel)..."

  local EXISTS
  EXISTS="$(sqlite3 "$MENU_DB" "SELECT COUNT(*) FROM menu WHERE id='$MODULE_NAME';")"

  if [[ "$EXISTS" -gt 0 ]]; then
    warn "Menu id '$MODULE_NAME' já existe. Mantendo."
  else
    sqlite3 "$MENU_DB" "INSERT INTO menu (id, IdParent, Link, Name, Type, order_no)
                        VALUES ('$MODULE_NAME', 'pbxconfig', '', 'Issabel Panel', 'module', 8);"
    log "Menu criado em pbxconfig."
  fi
}

restart_services() {
  log "Reiniciando Apache..."
  systemctl restart httpd
  log "Apache reiniciado."
}

final_checks() {
  log "Checks finais..."

  local RID
  RID="$(sqlite3 "$ACL_DB" "SELECT id FROM acl_resource WHERE name='$MODULE_NAME' LIMIT 1;")"

  echo
  echo "==== ACL RESOURCE ===="
  sqlite3 "$ACL_DB" "SELECT id,name,description FROM acl_resource WHERE id=$RID;"

  echo
  echo "==== MODULE PRIVILEGES ===="
  sqlite3 "$ACL_DB" "SELECT id,id_resource,privilege,desc_privilege FROM acl_module_privileges WHERE id_resource=$RID;"

  echo
  echo "==== GROUP PERMISSIONS (administrator) ===="
  sqlite3 "$ACL_DB" "SELECT * FROM acl_module_group_permissions WHERE id_group=$ADMIN_GROUP_ID AND id_module_privilege IN
                      (SELECT id FROM acl_module_privileges WHERE id_resource=$RID);"

  echo
  echo "==== MENU ENTRY ===="
  sqlite3 "$MENU_DB" "SELECT id,IdParent,Name,Type,order_no FROM menu WHERE id='$MODULE_NAME';"

  echo
  log "Finalizado ✅"
  echo
  echo "Acesse:"
  echo "  Issabel GUI -> PBX -> Issabel Panel"
  echo "Ou direto:"
  echo "  index.php?menu=control_panel"
  echo
}

# ===================== MAIN =====================
need_root
install_deps
validate_env
clone_repo
install_module_files

RID="$(ensure_acl_resource)"
ensure_module_privileges "$RID"
ensure_group_permissions_for_privileges "$RID"
ensure_group_action_access "$RID"
ensure_menu_entry
restart_services
final_checks
