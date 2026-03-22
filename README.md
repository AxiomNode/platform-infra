# platform-infra

Infraestructura y despliegue de plataforma para AxiomNode.

## Objetivo

- Definir infraestructura como codigo por entorno.
- Mantener configuraciones de Kubernetes y componentes compartidos.
- Estandarizar proceso de provisionamiento y despliegue.

## Estructura

- `terraform/`: recursos de infraestructura base.
- `kubernetes/base/`: manifiestos base para workloads.
- `environments/`: overlays por entorno (`dev`, `stg`, `prod`).

## CI

Incluye `validate-infra.yml` para verificar layout minimo esperado.
