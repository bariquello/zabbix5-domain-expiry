# Zabbix Domain Expiry Monitor (Zabbix 5.0)

Template e script para monitorar expiraçª£o de domÃınios .br e genÃ©ricos usando Zabbix 5.0.x.

## ðŸ“‹ Ìndice

- [VisÃ£o Geral](#visÃ£o-geral)
- [Requisitos](#requisitos)
- [Instalaçª£o](#instalaçª£o)
  - [1. Instalar DependÃªncias](#1-instalar-dependÃªncias)
  - [2. Configurar Script](#2-configurar-script)
  - [3. Criar Template no Zabbix](#3-criar-template-no-zabbix)
  - [4. Configurar Triggers](#4-configurar-triggers)
  - [5. Criar Hosts](#5-criar-hosts)
- [Importaçª£o em Massa](#importaçª£o-em-massa)
- [Configurar Alertas](#configurar-alertas)
- [Soluçª£o de Problemas](#soluçª£o-de-problemas)
- [Estrutura de Arquivos](#estrutura-de-arquivos)

---

## VisÃ£o Geral

Este projeto monitora a data de expiraçª£o de domÃınios usando:
- **Script externo** (`check_domain.sh`) que consulta RDAP/WHOIS
- **Template Zabbix 5.0** com item do tipo *External check*
- **4 triggers** para diferentes nÃıveis de criticidade

### Estados Monitorados

| Estado | Descriçª£o | Severidade |
|--------|------------|------------|
| `EXPIRED` | DomÃınio expirado | Disaster |
| `CRITICAL` | Expira em < 7 dias | High |
| `WARNING` | Expira em < 30 dias | Average |
| `ERROR` | Erro na consulta | Warning |

---

## Requisitos

- **Zabbix Server** 5.0.x
- **Linux** (Ubuntu/Debian ou RHEL/CentOS)
- **Acesso root** no servidor Zabbix
- **Pacotes**: `whois`, `jq`, `curl`, `gawk`

---

## Instalaçª£o

### 1. Instalar DependÃªncias

#### Debian/Ubuntu

```bash
sudo apt update
sudo apt install -y whois jq curl gawk
```

#### RHEL/CentOS/Rocky

```bash
sudo dnf install -y epel-release
sudo dnf install -y whois jq curl gawk
```

---

### 2. Configurar Script

#### Copiar Script

```bash
# Clone ou baixe o repositÃ³rio
git clone https://github.com/SEU-USUARIO/zabbix-domain-expiry.git
cd zabbix-domain-expiry

# Copie o script para o diretÃ³rio de ExternalScripts
sudo cp check_domain.sh /usr/lib/zabbix/externalscripts/

# Torne executÃ¡vel
sudo chmod +x /usr/lib/zabbix/externalscripts/check_domain.sh

# Ajuste permissÃµes (usuÃ¡rio zabbix)
sudo chown zabbix:zabbix /usr/lib/zabbix/externalscripts/check_domain.sh
```

#### Verificar Caminho no Zabbix

Edite `/etc/zabbix/zabbix_server.conf`:

```bash
# Verifique ou adicione:
ExternalScripts=/usr/lib/zabbix/externalscripts
```

Reinicie o Zabbix:

```bash
sudo systemctl restart zabbix-server
```

#### Testar Manualmente

```bash
sudo -u zabbix /usr/lib/zabbix/externalscripts/check_domain.sh google.com.br
```

**SaÃıda esperada:**

```json
{"state":"OK","days_left":272,"expire_date":"2027-05-18"}
```

---

### 3. Criar Template no Zabbix

#### Passo a Passo

1. **Acesse**: `Configuration → Templates`
2. **Clique em**: `Create template`
3. **Preencha**:

| Campo | Valor |
|-------|-------|
| Template name | `Domain Expiry` |
| Visible name | `Domain Expiry` |
| Groups | `Templates` |

4. **Clique em**: `Save`

#### Adicionar Item

1. **Selecione o template**: `Domain Expiry`
2. **VÃ¡ em**: `Items → Create item`
3. **Preencha**:

| Campo | Valor |
|-------|-------|
| Name | `Domain Expiry Check` |
| Type | `External check` |
| Key | `check_domain.sh[{HOST.HOST}]` |
| Type of information | `Text` |
| Update interval | `1d` |
| History storage period | `7d` |

4. **Clique em**: `Save`

---

### 4. Configurar Triggers

Crie **4 triggers** no template:

#### Trigger 1: EXPIRED

| Campo | Valor |
|-------|-------|
| Name | `Domain {HOST.HOST} EXPIRED` |
| Severity | `Disaster` |
| Expression | `{Domain Expiry:check_domain.sh[{HOST.HOST}].str("EXPIRED")}=1` |

#### Trigger 2: CRITICAL

| Campo | Valor |
|-------|-------|
| Name | `Domain {HOST.HOST} expiring in less than 7 days` |
| Severity | `High` |
| Expression | `{Domain Expiry:check_domain.sh[{HOST.HOST}].str("CRITICAL")}=1` |

#### Trigger 3: WARNING

| Campo | Valor |
|-------|-------|
| Name | `Domain {HOST.HOST} expiring in less than 30 days` |
| Severity | `Average` |
| Expression | `{Domain Expiry:check_domain.sh[{HOST.HOST}].str("WARNING")}=1` |

#### Trigger 4: ERROR

| Campo | Valor |
|-------|-------|
| Name | `Domain {HOST.HOST} check ERROR` |
| Severity | `Warning` |
| Expression | `{Domain Expiry:check_domain.sh[{HOST.HOST}].str("ERROR")}=1` |

---

### 5. Criar Hosts

Para cada domÃınio:

1. **Configuration → Hosts → Create host**
2. **Preencha**:

| Campo | Valor |
|-------|-------|
| Host name | `exemplo.com.br` |
| Visible name | `exemplo.com.br` |
| Groups | `DomÃınios` (crie se necessÃ¡rio) |
| Templates | `Domain Expiry` |

3. **Clique em**: `Save`

**Importante**: O nome do host **deve ser exatamente o domÃınio** (ex: `google.com.br`).

---

## Importaçª£o em Massa

### Script Python

Use o script `importar_dominios_zabbix_v5.py` para importar mÃºltiplos domÃınios de uma vez.

#### Requisitos

```bash
python3 -m pip install pyzabbix requests
```

#### Uso

```bash
python importar_dominios_zabbix_v5.py \
  --csv Dominios-Painel-Registrobr.csv \
  --url "http://SEU-ZABBIX/zabbix" \
  --usuario Admin \
  --template "Domain Expiry"
```

#### CSV do Registro.br

1. Acesse [Registro.br](https://registro.br)
2. VÃ¡ em **Meus DomÃınios**
3. Exporte CSV
4. Salve como `Dominios-Painel-Registrobr.csv`

O script:
- ✅ LÃª o CSV exportado
- ✅ Cria hosts automaticamente
- ✅ Anexa o template
- ✅ Agrupa em "DomÃınios"

---

## Configurar Alertas

### 1. Verificar Email

**Administration → General → Email**

Configure SMTP se ainda nÃ£o estiver:

| Campo | Exemplo |
|-------|---------|
| SMTP server | `smtp.seudominio.com` |
| SMTP port | `587` |
| SMTP helo | `seudominio.com` |
| SMTP email | `zabbix@seudominio.com` |

---

### 2. Configurar UsuÃ¡rio

**Administration → Users → [seu usuÃ¡rio] → Media → Add**

| Campo | Valor |
|-------|-------|
| Type | `Email` |
| Send to | `seu-email@seudominio.com` |
| When active | `1-7,00:00-24:00` |
| Use if severity | `Warning`, `Average`, `High`, `Disaster` |

---

### 3. Criar Action

**Configuration → Actions → Create action**

| Campo | Valor |
|-------|-------|
| Name | `Domain Expiry Alerts` |
| Event source | `Triggers` |

#### Conditions

| Type | Operator | Value |
|------|----------|-------|
| Trigger name | `contains` | `Domain` |

#### Operations

**Default message**:

```
Subject: {TRIGGER.SEVERITY}: {TRIGGER.NAME}

Message:
Host: {HOST.NAME}
Domain: {HOST.HOST}
Status: {ITEM.LASTVALUE}
Severity: {TRIGGER.SEVERITY}
Date: {EVENT.DATE} {EVENT.TIME}
```

**Send to users**: Selecione seu usuÃ¡rio

---

## Soluçª£o de Problemas

### Script nÃ£o funciona manualmente

```bash
# Verifique permissÃµes
ls -la /usr/lib/zabbix/externalscripts/check_domain.sh

# Teste como zabbix
sudo -u zabbix /usr/lib/zabbix/externalscripts/check_domain.sh google.com.br
```

### Item nÃ£o coleta dados

1. **Verifique o log**:

```bash
sudo tail -f /var/log/zabbix/zabbix_server.log | grep -i "check_domain"
```

2. **Force coleta**:
   - VÃ¡ em `Monitoring → Latest data`
   - Selecione o host
   - Clique em `Refresh`

3. **Reduza intervalo temporariamente**:
   - Mude `Update interval` de `1d` para `1m`
   - Aguarde 1-2 minutos
   - Volte para `1d`

### Erro "No interfaces for host"

O Zabbix 5.0 exige pelo menos uma interface. Ao criar hosts via script, uma interface dummy (127.0.0.1:10050) ÃƒÂ© adicionada automaticamente.

### Triggers nÃ£o disparam

Verifique:
- **Expression** estÃ¡ correta (case-sensitive)
- **Item** estÃ¡ coletando dados
- **Action** estÃ¡ configurada corretamente

---

## Estrutura de Arquivos

```
zabbix-domain-expiry/
├── README.md                          # Este arquivo
├── check_domain.sh                    # Script de monitoramento
├── importar_dominios_zabbix_v5.py     # Script de importaçª£o em massa
├── dominios.csv                       # CSV de exemplo (opcional)
└── templates/
    └── zbx_domain_expiry_v5.xml       # Template XML (opcional)
```

---

## Notas

- **Intervalo padrÃ£o**: 1 dia (ajuste conforme necessidade)
- **Aviso**: 30 dias antes da expiraçª£o
- **CrÃıtico**: 7 dias antes da expiraçª£o
- **Suporte**: DomÃınios .br e maioria dos TLDs

---

## Licençª£o

MIT License - Sinta-se ÃƒÂ¡ vontade para usar e modificar.

---

## Autor

Desenvolvido para monitoramento de domÃınios em ambiente de produçª£o com Zabbix 5.0 LTS.
