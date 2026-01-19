# Issabel 5 - Control Panel by David Oliveira WhatsApp +5516 981703272

Este repositório fornece um script automatizado para instalar e habilitar o módulo **Issabel Panel / Control Panel** no **Issabel 5**, incluindo:

✅ Instalação do módulo `control_panel` em `/var/www/html/modules/`  
✅ Correção completa de permissões ACL no banco `acl.db` (incluindo privilégios do módulo)  
✅ Inserção no menu do Issabel (`menu.db`) em **PBX → Issabel Panel**  
✅ Compatível com instalação via SSH (produção)

> ✅ Testado em ambiente Rocky Linux + Issabel 5

---

## 📌 O que este script resolve?

Ao instalar manualmente o `control_panel`, muitos usuários conseguem copiar a pasta corretamente, mas o módulo:

- não aparece no menu
- não aparece em *System → Group Permissions*
- não abre mesmo com permissões básicas

Isso ocorre porque o Issabel 5 exige não apenas o `acl_resource`, mas também o cadastro em:

- `acl_module_privileges`
- `acl_module_group_permissions`
- e em alguns casos, `acl_group_permission`

Este script aplica tudo automaticamente.

---

## ✅ Pré-requisitos

- Issabel 5 instalado e funcional
- Acesso SSH com usuário `root` ou `sudo`
- Internet liberada para baixar o repositório do módulo
- Apache (`httpd`) instalado (padrão no Issabel)

---

## 🚀 Instalação rápida

### 1) Baixar o script no servidor (SSH)

Crie o arquivo no servidor:

```bash
nano controlpanel.sh

Direitos de cópia colocando os dados autor nos créditos.
