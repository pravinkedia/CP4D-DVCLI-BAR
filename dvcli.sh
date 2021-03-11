#!/bin/bash
################################################################################
#
# Licensed Materials - Property of IBM
#
# "Restricted Materials of IBM"
#
# (C) COPYRIGHT IBM Corp. 2018 All Rights Reserved.
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with IBM Corp.
#
################################################################################

LINE="-----------------------------------------------------"

VALUE_INT_YES=0
VALUE_INT_NO=1

EC_SUCCESS=$VALUE_INT_YES
EC_ERROR=$VALUE_INT_NO

EXIST=$VALUE_INT_YES
NOT_EXIST=$VALUE_INT_NO

DV_ENGINE="dv-engine-0"
BAR_YARML_DIR="/opt/dv/current/bar/yaml"
BAR_PV="/mnt/PV/bar"

CURRENT_TIMESTAMP=""
DV_BAR_SA="dv-bar-sa"
STORAGE_CLASS="nfs-client"

OPERATION_BAR="bar"
ACTION_BACKUP="backup"
ACTION_RESTORE="restore"
ACTION_LIST="list"

NAMESPACE=""

EXT_COMMANDS=""

DV_BACKUP_JOB_YAML="dv-backup-job.yaml"
DV_RESTORE_JOB_YAML="dv-restore-job.yaml"

Usage (){
cat << EOF

DETAILED OPTIONS HELP
    -a | --action
      Action. "backup", "restore", "list"
    -o | --operation
      Operation. "bar"
    -b | --backup
      Backup. Optional parameter. BAR will use the latest backup by default
    -n | --namespace
      Namespace. Optional parameter. BAR will run without specifying namespace by default, i.e run against current namespace set in oc cli
    --storage-class
      Storage class used to create DV BAR PVC. BAR will use nfs-client storage class by default 
    -h | --help
      Displays this text
EOF
}

while true; do
  case "$1" in
    -a | --action ) ACTION="$2"; shift ;;
    -o | --operation ) OPERATION="$2"; shift ;;
    -b | --backup ) DV_BACKUP="$2"; shift ;;
    -n | --namespace ) NAMESPACE="$2"; shift ;;
    --storage-class ) STORAGE_CLASS="$2"; shift ;;
    -h | --help ) Usage; exit ;;
    (-*) echo "$0: The specific option $1 is not recognized" 1>&2; exit ${VALUE_INT_NO} ;;
     (*) break ;;
  esac
  shift
done

get_timestamp(){
  local current_date_time=$(date -u +"%Y-%m-%d_%H.%M.%S.%3N_%Z")
  echo $current_date_time
}

log_entry(){
  local level=$1
  local msg=$2
  local plain=$3

  timestamp=$(get_timestamp)

  if [ "${plain}" == "true" ]; then
    output="${msg}" 
  else
    output="${timestamp}  ${level} ${msg}"
  fi

  echo -e ${output} >&2 # Print logs to std err (screen) so we can still echo/return results from functions
  SCRIPT_LOG="dvcli_${CURRENT_TIMESTAMP}.log"
  echo -e ${output} >> ${SCRIPT_LOG}

}

log_warn(){
  log_entry 'WARN' "$1"
}

log_info(){
  log_entry 'INFO' "$1"
}

log_error(){
  log_entry 'ERROR' "$1"
}

#
# Check command exit code. Print info and error messages.
# Exit the script execution by default. Pass in 4th parameter with value 0 to not exit the script execution.
#
check_command_result(){
  local ec=$1
  local info_msg=$2
  local error_msg=$3
  local exit_on_error=${4:-0}

  if [ $ec -ne ${VALUE_INT_YES} ]; then
    log_error "${error_msg}"
    if [ ${exit_on_error} -eq ${VALUE_INT_YES} ]; then
      exit ${EC_ERROR}
    else
      # Still need to return the original exit code
      return $ec
    fi
  else
    log_info "${info_msg}"
    # Return EC_SUCCESS exit code
    return ${EC_SUCCESS}
  fi
}

init_parameters(){
  CURRENT_TIMESTAMP=$(get_timestamp)
  log_info "$LINE"
  log_info "${CURRENT_TIMESTAMP}"
  log_info "Operation: ${OPERATION}"
  log_info "Action: ${ACTION}"
  log_info "Storage Class: ${STORAGE_CLASS}"
  log_info "Backup: ${DV_BACKUP}"
  if [ "${NAMESPACE}" == "" ]; then
    log_info "No namespace specified" 
    log_info "Run BAR against current namespace set in oc cli"
  else
    log_info "Namespace: ${NAMESPACE}"
    EXT_COMMANDS="-n ${NAMESPACE}"
  fi
  log_info "$LINE"
}

precheck(){
  log_info "Precheck ${OPERATION}"
  if [ "${OPERATION}" == "${OPERATION_BAR}" ]; then
    log_info "Run OC Command: oc ${EXT_COMMANDS} get sa | grep -i ${DV_BAR_SA}"
    oc ${EXT_COMMANDS} get sa | grep -i ${DV_BAR_SA}
    ec=$?
    check_command_result $ec "${DV_BAR_SA} exist" "${DV_BAR_SA} does not exist. Make sure required security settings are configured"
  fi
}

download_from_pod(){
  local pod=$1
  local file=$2
  log_info "Run OC comamnd: oc ${EXT_COMMANDS} cp ${pod}:${file} $(basename ${file})"
  oc ${EXT_COMMANDS} cp ${pod}:${file} $(basename ${file})
  ec=$?
  check_command_result $ec "${file} is downloaded to current dir" "Failed to download ${file} to current dir"
}

#Check to see if the resource exist
check_k8s_resource(){
  local resource_type=$1
  local resource_name=$2
  resource_found=$(get_k8s_resource $resource_type $resource_name)
  if [ "$resource_found" != "" ]; then
    return $VALUE_INT_YES
  else
    return $VALUE_INT_NO
  fi
}

get_k8s_resource(){
  local resource_type=$1
  local resource_name=$2
  resource_found=$(oc ${EXT_COMMANDS} get $resource_type | grep -i $resource_name | cut -d' ' -f1)
  echo $resource_found
}

check_job_status(){
  local dv_bar_job
  dv_bar_job=$1
  log_info "Check $dv_bar_job status"
  attempts=120 #wait for 120 attempts * 30sec timeout on each attempt = an hour
  while [ $attempts -ne 0 ]
  do
    job_status=$(oc ${EXT_COMMANDS} get job $dv_bar_job -o jsonpath="{.status.conditions[0].type}")
    ec=$?
    if [ $ec -eq $EC_ERROR ]; then
      log_error "$dv_bar_job does not exist"
      return $ec
    fi
    if [ "$job_status" == "Complete" ]; then
      log_info "$dv_bar_job has finished. Exit"
      dv_bar_job_pod=$(get_k8s_resource "pod" $dv_bar_job)
      log_info "Save $dv_bar_job_pod pod log to $dv_bar_job_pod-$CURRENT_TIMESTAMP.log"
      oc ${EXT_COMMANDS} logs $dv_bar_job_pod > $dv_bar_job_pod-$CURRENT_TIMESTAMP.log
      return $EC_SUCCESS
    else
      if [[ "$job_status" == *'rror'* ]]; then
        log_error "$job_status"
        return $ec
      else
        log_info "$dv_bar_job is still running. Recheck in 30 seconds"
        sleep 30
        attempts=$(expr $attempts - 1)
      fi
    fi
  done

  #Only reach here if dv bar job did not finish before the timeout
  log_error "$dv_bar_job did not finish before the timeout of 60 minutes"
  return $EC_ERROR
}

update_dv_bar_yaml(){
  local yaml_file=$1
  dv_init_volume_job=$(oc ${EXT_COMMANDS} get job | grep -i dv-init-volume | cut -d' ' -f1)
  dv_init_volume_image=$(oc ${EXT_COMMANDS} get job $dv_init_volume_job -o yaml | grep -i image | grep -i v1.5.0.0 | xargs)
  log_info "Use DV init image: $dv_init_volume_image in $yaml_file"
  sed -i '' "s,image: docker-registry.default.svc:5000/zen/dv-init-volume:v1.5.0.0,$dv_init_volume_image,g" $yaml_file
  ec=$?
  check_command_result $ec "$yaml_file updated" "Failed to update $yaml_file"
}

create_and_watch_dv_bar(){
  local yaml_file=$1
  local dv_bar_job_name=$2

  log_info "Run OC command: oc ${EXT_COMMANDS} create -f $yaml_file"
  oc ${EXT_COMMANDS} create -f $yaml_file
  ec=$?
  check_command_result $ec "DV BAR job $dv_bar_job_name is created" "Failed to create DV BAR job $dv_bar_job_name"
  check_job_status "$dv_bar_job_name"
}

backup(){
  check_k8s_resource "job" "dv-backup-job"
  ec=$?
  if [ $ec -eq $VALUE_INT_YES ]; then
    log_warn "DV backup job exists. Remove it"
    oc ${EXT_COMMANDS} delete job dv-backup-job
  fi

  download_from_pod "${DV_ENGINE}" "${BAR_YARML_DIR}/${DV_BACKUP_JOB_YAML}"
  oc ${EXT_COMMANDS} get pvc | grep -i dv-bar
  ec=$?
  if [ $ec -eq $VALUE_INT_NO ]; then
    log_info "dv-bar PVC does not exist. Create dv-bar PVC"
    download_from_pod "${DV_ENGINE}" "${BAR_YARML_DIR}/dv-bar-pvc.yaml"
    if [ "${STORAGE_CLASS}" != "" ]; then
      log_info "Update dv-bar-pvc.yaml with storage class: ${STORAGE_CLASS}"
      sed -i "s/storageClassName: \"managed-nfs-storage\"/storageClassName: \"${STORAGE_CLASS}\"/g" dv-bar-pvc.yaml
      oc ${EXT_COMMANDS} create -f dv-bar-pvc.yaml
      ec=$?
      check_command_result $ec "DV BAR PVC is created" "Failed to create DV BAR PVC"
    fi
  else
    log_info "dv-bar PVC exists, no need to recreate it"
  fi

  update_dv_bar_yaml "${DV_BACKUP_JOB_YAML}"
  create_and_watch_dv_bar "${DV_BACKUP_JOB_YAML}" "dv-backup-job"
}

restore(){
  check_k8s_resource "pvc" "dv-bar-pvc"
  ec=$?
  if [ $ec -eq $VALUE_INT_NO ]; then
    log_error "dv-bar PVC does not exist. DV can not restore persistent volumes without DV BAR PVC. Exit"
  fi

  check_k8s_resource "job" "dv-restore-job"
  ec=$?
  if [ $ec -eq $VALUE_INT_YES ]; then
    log_warn "DV backup job exists. Remove it"
    oc ${EXT_COMMANDS} delete job dv-restore-job
  fi

  download_from_pod "${DV_ENGINE}" "${BAR_YARML_DIR}/${DV_RESTORE_JOB_YAML}"
  update_dv_bar_yaml "${DV_RESTORE_JOB_YAML}"

  if [ "${DV_BACKUP}" != "" ]; then
    log_info "Update ${DV_RESTORE_JOB_YAML} with custom DV backup ${DV_BACKUP}"
    sed -i "s/value: \"dv_backup.tar.gz\"/value: \"${DV_BACKUP}\/dv_backup.tar.gz\"/g" "${DV_RESTORE_JOB_YAML}"
    ec=$?
    check_command_result $ec "${DV_RESTORE_JOB_YAML} updated" "Failed to update ${DV_RESTORE_JOB_YAML}"
  fi

  create_and_watch_dv_bar "${DV_RESTORE_JOB_YAML}" "dv-restore-job"
}

list_backups_in_pv(){
  local dv_list_backup_pod_name=$1
  log_info "${LINE}"
  log_info "Available backups: \n"
  #Do not print out the symbolic link
  backups_in_pv=$(oc ${EXT_COMMANDS} exec -it $dv_list_backup_pod_name -- ls -lt "${BAR_PV}" | grep -v total | grep -v dv_backup.tar.gz)
  while read -r line; do
    #Double check, do not print out the symbolic link
    if [[ "${line}" != *"dv_backup.tar.gz"* ]]; then
      a_backup=$(echo ${line##* })
      #Special way to print to both console and the log file. 
      #INFO is needed to respect the parameter order, it does not get printed
      #Use tabs to retain the formatting and move the output away from timestamps 
      log_entry "INFO" "\t\t\t\t${a_backup}" "true"
    fi
  done <<< "${backups_in_pv}"
  log_entry "INFO" "\n" "true"
  log_info "${LINE}"
}

list_backups(){
  check_k8s_resource "pvc" "dv-bar-pvc"
  ec=$?
  if [ $ec -eq $VALUE_INT_NO ]; then
    log_error "dv-bar PVC does not exist. DV can not list backup tar balls without DV BAR PVC. Exit"
    exit $VALUE_INT_NO
  fi

  check_k8s_resource "pod" "dv-list-backups"
  ec=$?
  if [ $ec -eq $VALUE_INT_NO ]; then
    log_warn "DV list backups pod does not exist. Create it"
    download_from_pod "${DV_ENGINE}" "${BAR_YARML_DIR}/dv-list-backups-job.yaml"
    update_dv_bar_yaml "dv-list-backups-job.yaml"
    oc ${EXT_COMMANDS} create -f "dv-list-backups-job.yaml"
    ec=$?
    check_command_result $ec "DV BAR job list backups is created" "Failed to create DV BAR job list backups"
  fi

  dv_list_backup_pod_name=$(get_k8s_resource "pod" "dv-list-backups-job")
  attempts=40 #wait for 10mins
  while [ $attempts -ne 0 ]
  do
    oc ${EXT_COMMANDS} get pod $dv_list_backup_pod_name | grep -i running
    ec=$?
    if [ $ec -eq $VALUE_INT_YES ]; then
      log_info "DV list backups pod $dv_list_backup_pod_name is running"
      break
    else
      log_info "DV list backups pod is not running. Recheck in 15 seconds"
      sleep 15
      attempts=$(expr $attempts - 1)
    fi
  done

  list_backups_in_pv $dv_list_backup_pod_name
}

###############################################
#Main starts here
###############################################

init_parameters

if [ "${OPERATION}" == "${OPERATION_BAR}" ]; then
  precheck
  if [ "${ACTION}" == "${ACTION_BACKUP}" ]; then
    backup
  elif [ "${ACTION}" == "${ACTION_RESTORE}" ]; then
    restore
  elif [ "${ACTION}" == "${ACTION_LIST}" ]; then
    list_backups
  fi
else
  log_error "Operation ${OPERATION} is not supported"
fi
