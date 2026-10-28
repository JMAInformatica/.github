# Workflows reutilizáveis da JMA Informática

Workflows de versão, imagem GHCR e instalador MSI para os repositórios privados da organização. O repositório chamador cola um workflow curto e aponta para cá:

```yaml
uses: JMAInformatica/.github/.github/workflows/<arquivo>@main
```

A versão é decidida uma vez por execução. Imagem e MSI só publicam.

## Antes do primeiro uso

### 1. Liberar estes workflows para a organização

No repositório `JMAInformatica/.github`:

**Settings → Actions → General → Access** (no fim da página)

Selecione **Accessible from repositories in the 'JMAInformatica' organization** e salve.

Sem isso, um repositório privado não consegue chamar `workflow_call` de outro repositório privado.

Nos repositórios chamadores, em **Settings → Actions → General**:

- **Actions permissions**: permitir actions e reusable workflows da organização.
- **Workflow permissions**: o `GITHUB_TOKEN` precisa aceitar as `permissions` do workflow (`contents: write` para a tag e o release, `packages: write` para o GHCR). Se a organização travar o token em somente leitura, a tag não é criada.

O push da tag usa o `GITHUB_TOKEN`. Um push feito por esse token não dispara outro workflow, então a tag diária não entra em loop. Não substitua esse push por um PAT.

### 2. Manter o pacote privado

O primeiro push cria o pacote em `ghcr.io` ligado ao repositório. Confirme na página do pacote que a visibilidade continua **privada**. O mesmo vale para a configuração da organização em Packages: visibilidade padrão privada.

A tag `edge` anda a cada push na branch padrão. Pacote público publicaria esse build diário.

Provenance sai em `mode=max`. O pacote privado é o que impede esse metadado de build de ficar público. Argumento de build é dado público: o workflow recusa `build-args` cujo nome termina em `token`, `password`, `secret`, `private_key` ou `api_key`.

## Esquema de versão

Fuso de todas as datas: **America/Fortaleza**. Um push às 22:00 em Fortaleza continua no dia local, mesmo que o runner esteja em UTC.

### Diária, a cada push na branch padrão

Formato `vAAAA.M.D.N`, sem zero à esquerda:

| Push | Tag git | Versão de marketing |
| --- | --- | --- |
| 1º de 5 de janeiro de 2026 | `v2026.1.5.1` | `2026.1.5.1` |
| 2º no mesmo dia | `v2026.1.5.2` | `2026.1.5.2` |
| 1º de 9 de agosto de 2026 | `v2026.8.9.1` | `2026.8.9.1` |

`N` começa em 1 e é o maior `N` já usado naquele dia, mais um. A conta lê as tags `vAAAA.M.D.*` que já existem. O job de versão usa `concurrency` no repositório (`cancel-in-progress: false`), então dois pushes no mesmo dia esperam a vez. Se mesmo assim a tag perder a corrida, o job busca o próximo `N`.

Há no máximo 99 builds por dia. O centésimo falha. `N` maior que 99 faria `dia * 100 + N` colidir com o dia seguinte.

A tag é anotada e aponta para o commit do workflow. Reexecutar o mesmo run reutiliza a tag em vez de gastar outro `N`.

### Final, sob demanda

Duas portas de entrada:

- `workflow_dispatch` com `bump` em `patch`, `minor` ou `major`, na branch padrão. Sem versão final anterior, `major` produz `1.0.0`, `minor` produz `0.1.0` e `patch` produz `0.0.1`.
- Push de uma tag `vX.Y.Z` já criada (exatamente três números, major menor que 100). Uma tag com major maior ou igual a 100, como `v2026.1.5`, não é final: o bump e a final anterior das notas ignoram ela. O calendário continua em `vAAAA.M.D.N`.

A final também reserva o `N` do dia, numa segunda tag `vAAAA.M.D.N`. Assim o próximo daily não reutiliza o mesmo ProductVersion. A tag que o usuário vê, e a do GitHub Release, é `vX.Y.Z`.

O release final leva notas geradas desde a final anterior (`gh release create --generate-notes`). O diário não abre release por si; o workflow de MSI abre o pre-release quando há instalador.

## ProductVersion e MajorUpgrade

O Windows Installer compara `major.minor.build`. Os limites são major ≤ 255, minor ≤ 255 e build ≤ 65535. O quarto campo é ignorado na atualização.

| Build | Versão de marketing | ProductVersion |
| --- | --- | --- |
| `v2026.1.5.1` diário | `2026.1.5.1` | `26.1.501` |
| `v2026.1.5.2` diário | `2026.1.5.2` | `26.1.502` |
| `v1.0.0` final, ainda em 5 de janeiro | `1.0.0` | `26.1.503` |
| `v2026.1.6.1` diário | `2026.1.6.1` | `26.1.601` |
| `v1.1.0` final em 2 de fevereiro, 1º build do dia | `1.1.0` | `26.2.201` |
| `v2026.12.31.1` | `2026.12.31.1` | `26.12.3101` |
| `v2027.1.1.1` | `2027.1.1.1` | `27.1.101` |

A fórmula, para os dois canais, é:

```text
ProductVersion = (ano % 100).(mês).(dia * 100 + N)
```

`26.1.502` é maior que `26.1.501`, `26.2.101` é maior que `26.1.3101` (o mês é o minor) e `27.1.101` é maior que `26.12.3101`. Com `N` de 1 a 99, cada par dia+N gera um build único.

A versão de marketing (`1.2.0` ou `2026.1.5.2`) é o que a pessoa vê: tag da imagem, título do release, nome do arquivo MSI e nome do produto. O MajorUpgrade olha só o ProductVersion. Um único contador de calendário faz o instalador mais novo substituir o anterior, diário ou final.

Usar `1.0.0` como ProductVersion quebraria essa ordem: o major 1 fica atrás de qualquer build de 2026, cujo major já é 26. O Windows recusaria instalar a final por cima do diário. O sentido inverso também ficaria torto: um diário de janeiro pareceria mais novo que uma final `2.0.0`.

Consequências práticas:

- Em Aplicativos e recursos, a coluna de versão mostra `26.1.503`. O nome do produto carrega o número de marketing, por exemplo `TrackOrbit 1.0.0`.
- Um diário publicado depois de uma final tem ProductVersion maior. Instalado por cima, ele substitui a final. O build mais recente ganha. A final estável é o release normal; o diário é pre-release.
- A sequência é monotônica de 2001-01-01 a 2099-12-31. Em 2100 o major voltaria a 0.
- Não troque o `UpgradeCode` do produto. É ele que amarra o upgrade.
- Máquina que já recebeu um MSI `26.x` não volta para um ProductVersion `1.x`. O caminho é para a frente.
- MSI antigo `1.x` recebe este upgrade, porque 26 é maior que 1.

O WiX recebe as duas variáveis. O comando de build roda em Git Bash, com `PRODUCT_VERSION` e `MARKETING_VERSION` no ambiente.

```xml
<Project Sdk="WixToolset.Sdk/5.*">
  <PropertyGroup>
    <ProductVersion Condition="'$(ProductVersion)' == ''">0.0.1</ProductVersion>
    <MarketingVersion Condition="'$(MarketingVersion)' == ''">0.0.0</MarketingVersion>
    <DefineConstants>ProductVersion=$(ProductVersion);MarketingVersion=$(MarketingVersion)</DefineConstants>
  </PropertyGroup>
</Project>
```

```xml
<Package Name="TrackOrbit $(var.MarketingVersion)"
         Version="$(var.ProductVersion)"
         Manufacturer="JMA Informática"
         UpgradeCode="00000000-0000-0000-0000-000000000000">
  <MajorUpgrade DowngradeErrorMessage="Uma versão mais nova já está instalada." />
</Package>
```

Mantenha o `UpgradeCode` que o produto já usa. O trecho acima só mostra o lugar dele.

## `version.yml`

Calcula a versão, cria a tag anotada e, na final, abre o GitHub Release.

```yaml
jobs:
  version:
    permissions:
      contents: write
    uses: JMAInformatica/.github/.github/workflows/version.yml@main
    with:
      bump: ${{ inputs.bump }}
```

### Inputs

| Input | Obrigatório | Padrão | Função |
| --- | --- | --- | --- |
| `bump` | não | vazio | `major`, `minor` ou `patch`. Vazio no push da branch padrão (diária) e no push de `vX.Y.Z`. |
| `tag` | não | vazio | Tag final explícita, com ou sem `v`. Não combine com `bump`. |

No push de `vX.Y.Z`, deixe os dois vazios. O workflow reconhece a tag pelo ref.

### Outputs

| Output | Exemplo diário | Exemplo final |
| --- | --- | --- |
| `version` | `2026.1.5.2` | `1.2.0` |
| `marketing_version` | `2026.1.5.2` | `1.2.0` |
| `tag` | `v2026.1.5.2` | `v1.2.0` |
| `date_tag` | `v2026.1.5.2` | `v2026.1.5.3` |
| `channel` | `daily` | `final` |
| `product_version` | `26.1.502` | `26.1.503` |
| `build_date` | `2026.1.5` | `2026.1.5` |
| `build_number` | `2` | `3` |
| `sha` | SHA completo | SHA completo |
| `sha_short` | 7 caracteres | 7 caracteres |
| `previous_final_tag` | vazio | `v1.1.0` ou vazio |

## `docker-publish.yml`

Publica em `ghcr.io` com cache `type=gha`, labels OCI (metadata-action v5), SBOM, provenance `mode=max` (build-push-action v6) e assinatura keyless do cosign (`id-token: write`). O login usa `GITHUB_TOKEN`. Nenhum segredo entra no build.

Se `test-command` vier preenchido, o workflow constrói `linux/amd64`, carrega a imagem local (sem atestação, porque o daemon não carrega provenance) e roda o comando com `$IMAGE=jma-test:local`. Falha no teste cancela o push. O push seguinte reaproveita o cache e grava SBOM e provenance. `platforms` precisa incluir `linux/amd64` quando há teste.

### Tags da imagem

| Canal | Tags |
| --- | --- |
| diário | `AAAA.M.D.N`, `edge`, `sha-xxxxxxx` |
| final | `X.Y.Z`, `X.Y`, `X`, `latest` |

`latest` só existe na final. `edge` só existe no diário.

### Inputs

| Input | Obrigatório | Padrão | Função |
| --- | --- | --- | --- |
| `dockerfile` | sim | | Caminho do Dockerfile. |
| `context` | não | `.` | Contexto do build. |
| `image` | não | `ghcr.io/<owner>/<repo>` em minúsculas | Precisa ser `ghcr.io/<owner>/<nome>`. |
| `target` | não | vazio | Estágio do Dockerfile. |
| `build-args` | não | vazio | Linhas `KEY=VALUE`. Sem segredo. |
| `platforms` | não | `linux/amd64` | Lista separada por vírgula. |
| `test-command` | não | vazio | Bash executado antes do push. `$IMAGE` aponta para a imagem local. |
| `version` | não | vazio | Versão já calculada, sem `v`. Obrigatória na matriz, junto com `channel`. |
| `channel` | não | vazio | `daily` ou `final` quando `version` vem de fora. |
| `bump` | não | vazio | Encaminhado ao cálculo interno quando `version` está vazio. |

### Outputs

| Output | Conteúdo |
| --- | --- |
| `image` | Nome sem tag, por exemplo `ghcr.io/jmainformatica/biblia_sagrada`. |
| `digest` | Digest publicado (`sha256:...`). |
| `tags` | Referências completas, uma por linha. |
| `version` | Versão de marketing sem `v`. |
| `channel` | `daily` ou `final`. |

Cache de cada imagem usa um scope próprio (nome + target), para uma matriz não misturar camadas.

Conferir a assinatura:

O SAN do certificado keyless é o workflow reutilizável (`job_workflow_ref` deste arquivo), não o workflow do repositório que publicou a imagem. A extensão de repositório do certificado é o chamador. Troque `<repo>` por esse repositório, por exemplo `ByllOps`.

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/JMAInformatica/\.github/\.github/workflows/docker-publish\.yml@.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --certificate-github-workflow-repository 'JMAInformatica/<repo>' \
  ghcr.io/jmainformatica/<repo>@<digest>
```

### Uma imagem

Arquivo pronto: [`examples/docker-single.yml`](examples/docker-single.yml).

```yaml
name: Publicar imagem

on:
  push:
    branches: [main]
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      bump:
        description: Incremento da versão final
        required: true
        type: choice
        default: patch
        options: [patch, minor, major]

permissions:
  contents: write
  packages: write
  id-token: write

jobs:
  publish:
    uses: JMAInformatica/.github/.github/workflows/docker-publish.yml@main
    with:
      dockerfile: Dockerfile
      context: .
      bump: ${{ inputs.bump }}
```

Troque `main` se a branch padrão for outra. O `workflow_dispatch` também precisa ser disparado nela.

### Várias imagens

A versão sai de um job só. A matriz recebe `version` e `channel`. Arquivo pronto: [`examples/docker-matrix.yml`](examples/docker-matrix.yml).

```yaml
jobs:
  version:
    permissions:
      contents: write
    uses: JMAInformatica/.github/.github/workflows/version.yml@main
    with:
      bump: ${{ inputs.bump }}

  image:
    needs: version
    permissions:
      contents: write
      packages: write
      id-token: write
    strategy:
      fail-fast: false
      matrix:
        include:
          - image: ghcr.io/jmainformatica/saleorbit-api
            dockerfile: src/Api/Dockerfile
            context: .
          - image: ghcr.io/jmainformatica/saleorbit-web
            dockerfile: web/Dockerfile
            context: web
            target: runner
    uses: JMAInformatica/.github/.github/workflows/docker-publish.yml@main
    with:
      version: ${{ needs.version.outputs.version }}
      channel: ${{ needs.version.outputs.channel }}
      image: ${{ matrix.image }}
      dockerfile: ${{ matrix.dockerfile }}
      context: ${{ matrix.context }}
      target: ${{ matrix.target }}
```

O job da imagem declara `contents: write` porque `docker-publish.yml` também sabe calcular a versão. Na matriz esse cálculo fica desligado; a permissão precisa existir na chamada.

## `msi-release.yml`

Runner `windows-latest`. Compila o WiX, assina se houver certificado, grava o SHA256 e anexa o MSI ao release.

| Canal | Release |
| --- | --- |
| diário | pre-release, sem marcar como latest |
| final | release normal |

O arquivo publicado é `<produto>-<versão de marketing>.msi`, mais `<arquivo>.msi.sha256` no formato do `sha256sum`. Os dois também sobem como artefato do workflow por 30 dias. O corpo do release ganha um bloco `jma-msi` com o hash e o ProductVersion.

Sem `WINDOWS_CERTIFICATE_BASE64`, a assinatura é pulada e o workflow segue. Com certificado e sem senha, falha. O PFX fica só no passo de assinatura e é apagado no final. O comando de build não vê o certificado.

### Inputs

| Input | Obrigatório | Padrão | Função |
| --- | --- | --- | --- |
| `project` | sim | | Caminho do `.wixproj`, `.sln` ou projeto WiX. Também exposto como `$PROJECT_PATH`. |
| `build-command` | sim | | Bash. Variáveis: `PRODUCT_VERSION`, `MARKETING_VERSION`, `VERSION_TAG`, `VERSION_CHANNEL`, `PROJECT_PATH`. |
| `msi-path` | não | vazio | Arquivo ou glob. Vazio aceita um único `*.msi` fora de `obj/`, ou o único que esteja numa pasta Release. |
| `product-name` | não | nome do repositório | Prefixo do arquivo publicado. |
| `dotnet-version` | não | vazio | SDK passado ao `setup-dotnet`. Vazio usa o SDK do runner. |
| `timestamp-url` | não | `http://timestamp.digicert.com` | Carimbo do tempo do `signtool`. |
| `version` | não | vazio | Versão de marketing já calculada, sem `v`. |
| `channel` | não | vazio | `daily` ou `final` quando `version` vem de fora. |
| `product-version` | não | vazio | ProductVersion. Na final informada por fora, é obrigatório. No diário, se vier vazio, é derivado de `AAAA.M.D.N`. |
| `bump` | não | vazio | Encaminhado ao cálculo interno quando `version` está vazio. |

### Secrets

| Secret | Obrigatório | Função |
| --- | --- | --- |
| `WINDOWS_CERTIFICATE_BASE64` | não | PFX em Base64. |
| `WINDOWS_CERTIFICATE_PASSWORD` | não | Senha do PFX. |

Podem viver no repositório ou na organização. O exemplo repassa os dois; vazios significam “sem assinatura”.

### Outputs

| Output | Conteúdo |
| --- | --- |
| `version` | Versão de marketing sem `v`. |
| `marketing_version` | O mesmo valor. |
| `channel` | `daily` ou `final`. |
| `product_version` | Valor gravado no MSI. |
| `tag` | Tag do release. |
| `msi_name` | Nome do arquivo, por exemplo `TrackOrbit-1.2.0.msi`. |
| `sha256` | Hash em hexadecimal minúsculo. |
| `release_url` | URL do GitHub Release. |

### Repo de MSI

Arquivo pronto: [`examples/msi-desktop.yml`](examples/msi-desktop.yml). O caminho do projeto é ilustrativo: aponte para o `.wixproj` real. No TrackOrbit e na pasta `desktop/` do SaleOrbit a forma é a mesma.

```yaml
name: Publicar MSI

on:
  push:
    branches: [main]
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      bump:
        description: Incremento da versão final
        required: true
        type: choice
        default: patch
        options: [patch, minor, major]

jobs:
  msi:
    permissions:
      contents: write
    uses: JMAInformatica/.github/.github/workflows/msi-release.yml@main
    with:
      project: desktop/TrackOrbit.wixproj
      product-name: TrackOrbit
      dotnet-version: 10.0.x
      bump: ${{ inputs.bump }}
      build-command: |
        dotnet build "$PROJECT_PATH" -c Release \
          -p:ProductVersion="$PRODUCT_VERSION" \
          -p:MarketingVersion="$MARKETING_VERSION"
    secrets:
      WINDOWS_CERTIFICATE_BASE64: ${{ secrets.WINDOWS_CERTIFICATE_BASE64 }}
      WINDOWS_CERTIFICATE_PASSWORD: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}
```

SaleOrbit, se publicar imagens e o MSI no mesmo workflow, calcula a versão uma vez:

```yaml
jobs:
  version:
    permissions:
      contents: write
    uses: JMAInformatica/.github/.github/workflows/version.yml@main
    with:
      bump: ${{ inputs.bump }}

  image:
    needs: version
    permissions:
      contents: write
      packages: write
      id-token: write
    uses: JMAInformatica/.github/.github/workflows/docker-publish.yml@main
    with:
      dockerfile: Dockerfile
      version: ${{ needs.version.outputs.version }}
      channel: ${{ needs.version.outputs.channel }}

  msi:
    needs: version
    permissions:
      contents: write
    uses: JMAInformatica/.github/.github/workflows/msi-release.yml@main
    with:
      project: desktop/SaleOrbit.wixproj
      product-name: SaleOrbit
      version: ${{ needs.version.outputs.version }}
      channel: ${{ needs.version.outputs.channel }}
      product-version: ${{ needs.version.outputs.product_version }}
      build-command: |
        dotnet build "$PROJECT_PATH" -c Release \
          -p:ProductVersion="$PRODUCT_VERSION" \
          -p:MarketingVersion="$MARKETING_VERSION"
    secrets:
      WINDOWS_CERTIFICATE_BASE64: ${{ secrets.WINDOWS_CERTIFICATE_BASE64 }}
      WINDOWS_CERTIFICATE_PASSWORD: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}
```

## Padrão de `.env`

Cada projeto versiona um `.env.example` com todas as variáveis que o processo lê. O `.env` real fica no `.gitignore` e no `.dockerignore`. O compose aponta `env_file` para o `.env`. Segredo não entra na imagem e não entra em `build-args`.

`.gitignore` e `.dockerignore`:

```gitignore
.env
.env.*
!.env.example
```

```yaml
services:
  api:
    image: ghcr.io/jmainformatica/exemplo:edge
    env_file:
      - .env
```

Modelos em [`examples/env/`](examples/env/).

## O que roda neste repositório

`.github/workflows/lint.yml` executa actionlint 1.7.12 (com checksum), shellcheck e `tests/version_test.sh` (tags, ProductVersion, reexecução e dois builds paralelos no mesmo dia). Os YAML de `examples/` são modelos para colar nos outros repositórios: não disparam daqui, mas o actionlint confere a sintaxe.
