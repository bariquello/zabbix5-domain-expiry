#!/usr/bin/env python3
"""Importa dominios exportados do Registro.br como hosts no Zabbix (compativel com Zabbix 5.0)."""

import argparse
import csv
import getpass
import os
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse

try:
    import requests
    from pyzabbix import ZabbixAPI
except ImportError as e:
    sys.exit(f"Dependencia ausente. Instale com: python3 -m pip install {e.name}")


def testar_api(url):
    """Testa se a URL da API esta acessivel."""
    payload = {
        "jsonrpc": "2.0",
        "method": "apiinfo.version",
        "params": {},
        "id": 1
    }
    try:
        resp = requests.post(
            url,
            json=payload,
            headers={"Content-Type": "application/json-rpc"},
            timeout=5
        )
        if resp.status_code == 200:
            data = resp.json()
            if "result" in data:
                return True, data["result"]
        return False, f"HTTP {resp.status_code}"
    except Exception as e:
        return False, str(e)


def normalizar_url(url):
    """Garante que a URL termine corretamente para a API."""
    url = url.rstrip("/")
    parsed = urlparse(url)
    
    if parsed.path.endswith("api_jsonrpc.php"):
        return url
    
    if parsed.path.endswith("zabbix") or parsed.path == "":
        return urljoin(url, "api_jsonrpc.php")
    
    return urljoin(url, "api_jsonrpc.php")


def ler_dominios(caminho):
    """Le CSV do Registro.br e extrai lista de dominios."""
    dominios = []
    
    for encoding in ['utf-8-sig', 'utf-8', 'latin-1', 'cp1252']:
        try:
            with open(caminho, "r", encoding=encoding, newline="") as arquivo:
                leitor = csv.DictReader(arquivo)
                
                if not leitor.fieldnames:
                    continue
                
                coluna_dominio = leitor.fieldnames[0]
                print(f"Usando coluna: '{coluna_dominio}' (encoding: {encoding})")
                
                for linha in leitor:
                    valor = linha.get(coluna_dominio)
                    if valor:
                        dominio = valor.strip().lower().rstrip('"').lstrip('"')
                        if dominio and '.' in dominio:
                            if dominio not in dominios:
                                dominios.append(dominio)
                
                if dominios:
                    print(f"CSV lido com sucesso: {len(dominios)} dominios")
                    return dominios
                    
        except Exception:
            continue
    
    raise ValueError(f"Nao foi possivel ler o CSV: {caminho}")


def obter_id_grupo(zapi, nome):
    """Obtem ou cria grupo de hosts."""
    grupos = zapi.hostgroup.get(filter={"name": nome}, output=["groupid", "name"])
    if grupos:
        return grupos[0]["groupid"]
    
    resposta = zapi.hostgroup.create(name=nome)
    return resposta["groupids"][0]


def obter_id_template(zapi, nome):
    """Obtem ID do template por nome."""
    templates = zapi.template.get(filter={"host": nome}, output=["templateid", "host"])
    
    if not templates:
        templates = zapi.template.get(search={"host": nome}, output=["templateid", "host"])
    
    if not templates:
        templates = zapi.template.get(search={"name": nome}, output=["templateid", "name"])
    
    if not templates:
        raise RuntimeError(f"Template nao encontrado: {nome}")
    
    return templates[0]["templateid"]


def criar_host_zabbix5(zapi, dominio, groupid, templateid):
    """Cria host compativel com Zabbix 5.0 com interface dummy."""
    # Zabbix 5.0 exige pelo menos uma interface
    # Adicionamos interface Zabbix agent dummy (mesmo nao sendo usada)
    host_params = {
        "host": dominio,
        "name": dominio,
        "status": 0,
        "groups": [{"groupid": groupid}],
        "templates": [{"templateid": templateid}],
        "interfaces": [
            {
                "type": 1,  # 1 = Zabbix agent
                "main": 1,
                "useip": 1,
                "ip": "127.0.0.1",
                "dns": "",
                "port": "10050"
            }
        ]
    }
    
    try:
        zapi.host.create(**host_params)
        return True, None
    except Exception as e:
        return False, str(e)


def main():
    parser = argparse.ArgumentParser(
        description="Importa dominios do Registro.br para o Zabbix (v5.0+)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemplos:
  python importar_dominios_zabbix_v5.py --csv dominios.csv --dry-run
  python importar_dominios_zabbix_v5.py --csv dominios.csv --url http://zabbix/api_jsonrpc.php --usuario Admin
        """
    )
    parser.add_argument("--csv", default="Dominios-Painel-Registrobr.csv", help="Arquivo CSV com dominios")
    parser.add_argument("--url", default=os.getenv("ZABBIX_URL"), help="URL da API do Zabbix")
    parser.add_argument("--usuario", default=os.getenv("ZABBIX_USER"), help="Usuario do Zabbix")
    parser.add_argument("--senha", default=os.getenv("ZABBIX_PASSWORD"), help="Senha do Zabbix")
    parser.add_argument("--grupo", default="Dominios", help="Nome do grupo de hosts")
    parser.add_argument("--template", default="Domain Expiry", help="Nome do template")
    parser.add_argument("--dry-run", action="store_true", help="Apenas lista, nao cria hosts")
    parser.add_argument("--zabbix5", action="store_true", help="Forca modo compativel com Zabbix 5.0")
    
    args = parser.parse_args()

    # URL da API
    if not args.url:
        args.url = input("URL da API do Zabbix (ex: http://192.168.254.46/zabbix): ").strip()
    
    url_api = normalizar_url(args.url)
    print(f"URL da API: {url_api}")
    
    # Testa a API
    print("Testando API...", end=" ")
    ok, versao = testar_api(url_api)
    if ok:
        print(f"OK (Zabbix {versao})")
        try:
            versao_maior = int(versao.split(".")[0])
            if versao_maior < 6:
                args.zabbix5 = True
                print(f"Zabbix {versao} detectado - usando modo compativel com v5.x")
        except:
            pass
    else:
        print(f"FALHOU: {versao}")
        
        urls_teste = [
            args.url.rstrip("/") + "/api_jsonrpc.php",
            args.url.rstrip("/") + "/zabbix/api_jsonrpc.php",
            urljoin(args.url, "zabbix/api_jsonrpc.php"),
        ]
        
        for url_teste in urls_teste:
            ok, resultado = testar_api(url_teste)
            status = "OK" if ok else "FALHOU"
            print(f"  {status}: {url_teste}")
            if ok:
                url_api = url_teste
                print(f"\nUsando: {url_api}")
                break
        else:
            sys.exit("\nNenhuma URL da API funcionou. Verifique a instalacao do Zabbix.")
    
    # Dominios
    print(f"\nLendo CSV: {args.csv}")
    try:
        dominios = ler_dominios(Path(args.csv))
    except Exception as e:
        sys.exit(f"Erro ao ler CSV: {e}")
    
    print(f"Dominios encontrados: {len(dominios)}")

    if args.dry_run:
        print("Modo dry-run: nenhum host sera criado.")
        print("\n".join(dominios[:10]))
        if len(dominios) > 10:
            print(f"... e mais {len(dominios) - 10} dominios")
        return

    # Autenticacao
    if args.usuario:
        print(f"\nAutenticacao: usuario '{args.usuario}'")
    else:
        args.usuario = input("Usuario do Zabbix: ").strip()
        print(f"Autenticacao: usuario '{args.usuario}'")
    
    if not args.senha:
        args.senha = getpass.getpass("Senha do Zabbix: ")

    # Conecta
    zapi = ZabbixAPI(url_api)
    try:
        zapi.login(args.usuario, args.senha)
        print("Login realizado com sucesso!")
    except Exception as e:
        sys.exit(f"Erro no login: {e}")

    # Grupo
    try:
        groupid = obter_id_grupo(zapi, args.grupo)
        print(f"Grupo '{args.grupo}': ID {groupid}")
    except Exception as e:
        sys.exit(f"Erro ao buscar/criar grupo: {e}")

    # Template
    try:
        templateid = obter_id_template(zapi, args.template)
        print(f"Template '{args.template}': ID {templateid}")
    except Exception as e:
        print(f"\nERRO: {e}")
        print("\nTemplates disponiveis (busca parcial):")
        templates = zapi.template.get(output=["templateid", "host", "name"], search={"host": "domain"})
        for t in templates[:10]:
            print(f"  - {t['host']} (ID: {t['templateid']})")
        if len(templates) > 10:
            print(f"  ... e mais {len(templates) - 10}")
        sys.exit("\nUse --template com o nome correto.")

    # Lista hosts existentes
    existentes = {h["host"] for h in zapi.host.get(output=["host"])}
    print(f"Hosts existentes no Zabbix: {len(existentes)}")

    # Cria hosts
    criados = 0
    ignorados = 0
    falhas = 0
    
    for dominio in dominios:
        if dominio in existentes:
            print(f"[Ja existe] {dominio}")
            ignorados += 1
            continue
        
        sucesso, erro = criar_host_zabbix5(zapi, dominio, groupid, templateid)
        
        if sucesso:
            print(f"[CRIADO] {dominio}")
            criados += 1
        else:
            print(f"[ERRO] {dominio}: {erro}", file=sys.stderr)
            falhas += 1

    print(f"\n=== Resumo ===")
    print(f"Criados: {criados}")
    print(f"Ja existiam: {ignorados}")
    print(f"Falhas: {falhas}")
    
    zapi.user.logout()


if __name__ == "__main__":
    main()