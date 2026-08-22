#!/bin/sh
#===============================================
# Ambiente Docker Compose para Oracle Service Bus (OSB)
# Adaptado de: oracle/docker-images/OracleSOASuite/setenv.sh
#
# Corre isto DENTRO de uma shell Linux (WSL2 Ubuntu, com o Docker
# Desktop a usar o WSL2 backend). Os caminhos abaixo são caminhos
# Linux, não caminhos Windows.
#===============================================

# Diretório onde ficam os dados do domínio e da base de dados.
# Ajusta para o teu utilizador WSL2 se necessário.
export DC_USERHOME=${HOME}/osb-docker

# Registries onde as imagens já construídas (buildDockerImage.sh) ficam.
# "localhost" assume que fizeste `docker build` localmente sem push
# para nenhum registry remoto.
export DC_REGISTRY_SOA="localhost"
export DC_REGISTRY_DB="localhost"

# Proxy (descomenta e ajusta se estiveres atrás de um proxy corporativo)
#export http_proxy=""
#export https_proxy=""
#export no_proxy=""

#===============================================
exportComposeEnv() {
  export DC_HOSTNAME=$(hostname -f 2>/dev/null || hostname)

  # --- Base de dados Oracle (usada para as schemas RCU do OSB) ---
  export DC_ORCL_PORT=1521
  export DC_ORCL_OEM_PORT=5500
  export DC_ORCL_SID=soadb
  export DC_ORCL_PDB=soapdb
  # DEFINE UMA PASSWORD (min. 8 chars, 1 maiúscula, 1 número)
  export DC_ORCL_SYSPWD="MudaEsta1Pwd"
  export DC_ORCL_HOST=${DC_HOSTNAME}
  export DC_ORCL_DBDATA=${DC_USERHOME}/dbdata

  # --- Password do AdminServer WebLogic (login na consola) ---
  # user: weblogic
  export DC_ADMIN_PWD="MudaEsta1Pwd"

  # --- Password comum RCU + prefixo das schemas do OSB ---
  export DC_RCU_SCHPWD="MudaEsta1Pwd"
  export DC_RCU_OSBPFX=OSB01

  # --- Diretório de dados do domínio OSB ---
  export DC_DDIR_OSB=${DC_USERHOME}/osbdomain

  # --- Versão da imagem construída com buildDockerImage.sh ---
  export DC_SOA_VERSION=12.2.1.4
}

#===============================================
createDirs() {
  mkdir -p ${DC_ORCL_DBDATA} ${DC_DDIR_OSB}
  chmod 777 ${DC_ORCL_DBDATA} ${DC_DDIR_OSB}
}

#===============================================
#== MAIN
#===============================================
echo "INFO: A configurar ambiente Docker para OSB..."
exportComposeEnv
createDirs
echo "INFO: Variaveis definidas:"
env | grep -e "DC_" | sort
