#!/bin/bash
set -euo pipefail

# ==========================================================
# Issabel 5 - Control Panel (control_panel) Installer 
# Copyright David Oliveira  WhatsApp +55(16) 98170-3272
# ==========================================================
# ==========================================================
# Issabel 5 - Control Panel Installer
# Modo suportado:
#   classic  = PBX -> Issabel Panel
#   topmenu  = menu próprio "Control Panel" no topo
# Uso:
#   bash install_control_panel.sh
#   bash install_control_panel.sh classic
#   bash install_control_panel.sh topmenu
# ==========================================================

MODULES_DIR="/var/www/html/modules"
MODULE_NAME="control_panel"

REPO_URL="https://github.com/ISSABELPBX/panel-issabel5.git"
REPO_DIR="/usr/src/panel-issabel5"

ACL_DB="/var/www/db/acl.db"
MENU_DB="/var/www/db/menu.db"

ASTERISK_USER="asterisk"
ASTERISK_GROUP="asterisk"

# Ajuste se necessário no seu ambiente
ADMIN_GROUP_ID="1"

# classic | topmenu
MENU_MODE="${1:-classic}"

log()  { echo -e "\033[1;32m[OK]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[ERRO]\033[0m $*" >&2; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Execute como root: sudo bash $0 [classic|topmenu]"
    exit 1
  fi
}

check_mode() {
  case "$MENU_MODE" in
    classic|topmenu) ;;
    *)
      err "Modo inválido: $MENU_MODE"
      err "Use: classic ou topmenu"
      exit 1
      ;;
  esac
}

install_deps() {
  log "Instalando dependências (git, sqlite)..."
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install git sqlite
  else
    yum -y install git sqlite
  fi
}

validate_env() {
  log "Validando estrutura do Issabel..."
  [[ -d "$MODULES_DIR" ]] || { err "Não achei $MODULES_DIR"; exit 1; }
  [[ -f "$ACL_DB" ]]      || { err "Não achei $ACL_DB"; exit 1; }
  [[ -f "$MENU_DB" ]]     || { err "Não achei $MENU_DB"; exit 1; }
}

clone_repo() {
  log "Baixando/atualizando repositório do módulo..."
  mkdir -p /usr/src

  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only || {
      warn "git pull falhou. Mantendo conteúdo atual em $REPO_DIR"
    }
  else
    git clone "$REPO_URL" "$REPO_DIR"
  fi
}

install_module_files() {
  log "Instalando arquivos do módulo $MODULE_NAME..."

  [[ -d "$REPO_DIR/$MODULE_NAME" ]] || {
    err "Pasta não encontrada: $REPO_DIR/$MODULE_NAME"
    exit 1
  }

  if [[ -d "$MODULES_DIR/$MODULE_NAME" ]]; then
    BACKUP_DIR="${MODULES_DIR}/${MODULE_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
    warn "Módulo já existe. Criando backup em: $BACKUP_DIR"
    mv "$MODULES_DIR/$MODULE_NAME" "$BACKUP_DIR"
  fi

  cp -a "$REPO_DIR/$MODULE_NAME" "$MODULES_DIR/"

  chown -R "${ASTERISK_USER}:${ASTERISK_GROUP}" "$MODULES_DIR/$MODULE_NAME"
  find "$MODULES_DIR/$MODULE_NAME" -type d -exec chmod 755 {} \;
  find "$MODULES_DIR/$MODULE_NAME" -type f -exec chmod 644 {} \;

  if [[ ! -f "$MODULES_DIR/$MODULE_NAME/index.php" ]]; then
    warn "index.php não encontrado em $MODULES_DIR/$MODULE_NAME"
  fi

  log "Arquivos instalados em $MODULES_DIR/$MODULE_NAME"
}

get_resource_id() {
  sqlite3 "$ACL_DB" "SELECT id FROM acl_resource WHERE name='$MODULE_NAME' LIMIT 1;"
}

ensure_acl_resource() {
  log "Garantindo resource em acl_resource..."
  local RID
  RID="$(get_resource_id)"

  if [[ -n "$RID" ]]; then
    log "acl_resource já existe: id=$RID"
  else
    sqlite3 "$ACL_DB" \
      "INSERT INTO acl_resource (name, description) VALUES ('$MODULE_NAME', 'Control Panel');"
    RID="$(get_resource_id)"
    [[ -n "$RID" ]] || { err "Falha ao criar acl_resource"; exit 1; }
    log "acl_resource criado: id=$RID"
  fi

  echo "$RID"
}

ensure_module_privileges() {
  local RID="$1"
  log "Garantindo privilégios do módulo..."

  sqlite3 "$ACL_DB" \
    "INSERT OR IGNORE INTO acl_module_privileges (id_resource, privilege, desc_privilege)
     VALUES ($RID, 'access', 'Access Control Panel');"

  sqlite3 "$ACL_DB" \
    "INSERT OR IGNORE INTO acl_module_privileges (id_resource, privilege, desc_privilege)
     VALUES ($RID, 'view', 'View Control Panel');"

  log "Privilégios access/view OK"
}

ensure_group_permissions_for_privileges() {
  local RID="$1"
  local PID_ACCESS PID_VIEW

  log "Vinculando privilégios ao grupo administrator (id=$ADMIN_GROUP_ID)..."

  PID_ACCESS="$(sqlite3 "$ACL_DB" \
    "SELECT id FROM acl_module_privileges WHERE id_resource=$RID AND privilege='access' LIMIT 1;")"
  PID_VIEW="$(sqlite3 "$ACL_DB" \
    "SELECT id FROM acl_module_privileges WHERE id_resource=$RID AND privilege='view' LIMIT 1;")"

  [[ -n "$PID_ACCESS" ]] || { err "Privilege access não localizado"; exit 1; }
  [[ -n "$PID_VIEW"   ]] || { err "Privilege view não localizado"; exit 1; }

  sqlite3 "$ACL_DB" \
    "INSERT OR IGNORE INTO acl_module_group_permissions (id_group, id_module_privilege)
     VALUES ($ADMIN_GROUP_ID, $PID_ACCESS);"

  sqlite3 "$ACL_DB" \
    "INSERT OR IGNORE INTO acl_module_group_permissions (id_group, id_module_privilege)
     VALUES ($ADMIN_GROUP_ID, $PID_VIEW);"

  log "Grupo liberado para access/view"
}

ensure_group_action_access() {
  local RID="$1"
  log "Garantindo action access para o grupo..."

  if sqlite3 "$ACL_DB" ".tables" | grep -qw "acl_action"; then
    local ACTION_ID=""
    ACTION_ID="$(sqlite3 "$ACL_DB" \
      "SELECT id FROM acl_action WHERE name='access' LIMIT 1;" 2>/dev/null || true)"

    if [[ -z "$ACTION_ID" ]]; then
      ACTION_ID="1"
      warn "acl_action 'access' não localizado. Usando id_action=1"
    fi

    sqlite3 "$ACL_DB" \
      "INSERT OR IGNORE INTO acl_group_permission (id_action, id_group, id_resource)
       VALUES ($ACTION_ID, $ADMIN_GROUP_ID, $RID);"

    log "acl_group_permission OK"
  else
    warn "Tabela acl_action não localizada. Ignorando acl_group_permission"
  fi
}

ensure_classic_menu() {
  log "Garantindo menu clássico em PBX -> Issabel Panel..."

  local EXISTS
  EXISTS="$(sqlite3 "$MENU_DB" "SELECT COUNT(*) FROM menu WHERE id='$MODULE_NAME';")"

  if [[ "$EXISTS" -gt 0 ]]; then
    warn "Menu '$MODULE_NAME' já existe. Mantendo."
  else
    sqlite3 "$MENU_DB" \
      "INSERT INTO menu (id, IdParent, Link, Name, Type, order_no)
       VALUES ('$MODULE_NAME', 'pbxconfig', '', 'Issabel Panel', 'module', 8);"
    log "Menu clássico criado"
  fi
}

ensure_topmenu() {
  log "Garantindo menu top 'Control Panel'..."

  sqlite3 "$MENU_DB" \
    "UPDATE menu SET order_no=1 WHERE id='system';" || true

  local ROOT_EXISTS CHILD_EXISTS
  ROOT_EXISTS="$(sqlite3 "$MENU_DB" "SELECT COUNT(*) FROM menu WHERE id='menu_control_panel';")"
  CHILD_EXISTS="$(sqlite3 "$MENU_DB" "SELECT COUNT(*) FROM menu WHERE id='$MODULE_NAME';")"

  if [[ "$ROOT_EXISTS" -eq 0 ]]; then
    sqlite3 "$MENU_DB" \
      "INSERT INTO menu (id, IdParent, Link, Name, Type, order_no)
       VALUES ('menu_control_panel', '', '', 'Control Panel', '', 0);"
    log "Menu raiz menu_control_panel criado"
  else
    warn "Menu raiz menu_control_panel já existe"
  fi

  if [[ "$CHILD_EXISTS" -eq 0 ]]; then
    sqlite3 "$MENU_DB" \
      "INSERT INTO menu (id, IdParent, Link, Name, Type, order_no)
       VALUES ('$MODULE_NAME', 'menu_control_panel', '', 'Control Panel', 'module', 1);"
    log "Entrada control_panel criada em menu_control_panel"
  else
    warn "Entrada control_panel já existe"
  fi
}

ensure_menu() {
  case "$MENU_MODE" in
    classic) ensure_classic_menu ;;
    topmenu) ensure_topmenu ;;
  esac
}

restart_services() {
  log "Reiniciando Apache..."
  systemctl restart httpd
  log "Apache reiniciado"
}

final_checks() {
  local RID
  RID="$(get_resource_id)"

  echo
  echo "==== ACL RESOURCE ===="
  sqlite3 "$ACL_DB" \
    "SELECT id,name,description FROM acl_resource WHERE name='$MODULE_NAME';"

  echo
  echo "==== MODULE PRIVILEGES ===="
  sqlite3 "$ACL_DB" \
    "SELECT id,id_resource,privilege,desc_privilege
     FROM acl_module_privileges
     WHERE id_resource=$RID;"

  echo
  echo "==== GROUP PERMISSIONS ===="
  sqlite3 "$ACL_DB" \
    "SELECT *
     FROM acl_module_group_permissions
     WHERE id_group=$ADMIN_GROUP_ID
       AND id_module_privilege IN
       (SELECT id FROM acl_module_privileges WHERE id_resource=$RID);"

  echo
  echo "==== MENU ENTRY ===="
  sqlite3 "$MENU_DB" \
    "SELECT id,IdParent,Name,Type,order_no
     FROM menu
     WHERE id IN ('menu_control_panel','$MODULE_NAME');"

  echo
  log "Finalizado"
  echo
  echo "Acesso esperado:"
  if [[ "$MENU_MODE" == "classic" ]]; then
    echo "  Issabel GUI -> PBX -> Issabel Panel"
  else
    echo "  Menu superior -> Control Panel"
  fi
  echo "  URL direta: index.php?menu=control_panel"
  echo
}

main() {
  need_root
  check_mode
  install_deps
  validate_env
  clone_repo
  install_module_files

  local RID
  RID="$(ensure_acl_resource)"
  ensure_module_privileges "$RID"
  ensure_group_permissions_for_privileges "$RID"
  ensure_group_action_access "$RID"
  ensure_menu
  restart_services
  final_checks
}

main "$@"
 

