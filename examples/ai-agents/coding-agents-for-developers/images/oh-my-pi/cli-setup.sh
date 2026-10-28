#!/bin/sh
# oh-my-pi (omp) reaches Amazon Bedrock through its built-in amazon-bedrock provider and
# the pod's Pod Identity credentials; the model is selected on the command line (see the
# image's CLI_CMD) and the first-run wizard is skipped with OMP_SKIP_SETUP. Nothing needs
# to be written to the home here -- defining a custom model in models.yml would require a
# baseUrl the built-in provider supplies itself -- so this hook only ensures the config
# directory exists for omp's own session and log files.
set -eu
mkdir -p "$HOME/.omp/agent"
