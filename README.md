# CP4D-DVCLI-BAR

## Notes regarding DV BAR

1. DV 1.5.0 BAR uses DV's own backup and restore scripts. 
2. It runs an offline backup and restore against the same DV instance. 
3. Customers must not reprovision DV 1.5.0. 
4. All backups are full backups. 
5. DV does not run incremental backups in DV 1.5.0. 
6. The backup and restore are at the file system level. 
7. Files and directories in DV persistent volumes are tared and stored in a separate persistent volume. 
8. The starting point of the BAR feature is the dvcli.sh script shipped in the dv-engine-0 pod. 
9. The script helps you run backup, restore and list all existing backups. 
10. The script expects dv-init-volume pod (created by the DV init volume job) to exist in order to obtain necessary information about where to load the DV init volume Docker image.
11. This is the Docker image that runs the backup/restore logic.
12. DV 1.5.0 BAR feature is documented at https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/svc-dv/dv-bar.html

### Backup

#### Pre-backup manual steps

#####  Note: Each DV backup is about 10 Gi on the ROKS environment utilized for testing. 
#####  This causes dv-bar-pvc to run out of space very quickly if the customer sticks to the default 20Gi PVC size. They can either increase PV size (if ibmc-file-gold-gid supports it) or manually create dv-pvc-bar before running dvcli.sh. If you do decide to manually create dv-pvc-bar PVC, you can also apply workaround of issue 2 documented in the "Known issues and workarounds" section.

### DV Backup Steps - General workflow

##### Note: DV backup on this ROKS environment fails with error about files were changed during the tar process. 

1. The backup process already stops the backend, we can further stop dv-api, dv-caching and dv-unified console pod by scaling them to 0, before running the backup command
    oc scale --replicas=0 deployment dv-caching dv-api dv-unified-console
2. A user runs dvcli.sh script with correct parameters to start the backup. 
3. The script downloads necessary YAML files and modifies them based on information from dv-init-volume pod and parameter values passed in by the user.
4. The script creates a Kubernetes job to backup persistent volumes used by DV pods by creating a tar ball.
5. The job stops all DV components. It puts down a marker file to stop DV liveness probes from restarting DV pods
6. The job creates a tar ball and stores it in a separate persistent volume (not used by any DV instance pods) for storage
7. The backup tar ball from a freshly provisioned DV instance is about 3-4GB. 
8. If this persistent volume is deleted after DV backup job is executed. Users will loose all DV backups.
10. The job restarts DV components in DV instance pods and remove the backup marker file.
11. Restart dv-api, dv-caching and dv-unified-console pod
    oc scale --replicas=1 deployment dv-caching dv-api dv-unified-console

### Restore

1. A user runs dvcli.sh with correct parameters to start the restore.
2. We assume the persistent volume used to store DV backup tar balls are still there and contains at least one DV backup tar file.
3. Note: We need to make sure  All DV pods are running. oc get pods | grep -i dv | grep -v Complete
4. The latest backup was successful. This can be validated by looking at the content of /mnt/PV/bar (via the test job as documented in "Issue 2. DV backup pod keeps failing. oc logs dv-backup-xxxx shows a similar directory permission error as shown below")
5. If you really need to restore against an old backup. You will need to modify the symbolic link on /mnt/PV/bar to point to the desired dv_backup.tar.gz tar ball
6. The script downloads necessary YAML files and modifies them based on information from dv-init-volume pod and parameter values passed in by the user.
7. The job stops all DV components. It puts down a marker file to stop DV liveness probes from restarting DV pods
8. The job copies the tar ball from its own storage persistent volume to a shared persistent volume used by all DV instance pods
9. The job untars the tar ball to DV persistent volumes
10. The job restarts DV components in DV instance pods and remove the restore marker file.
11. Once dvcli.sh shows the restore is finished, run the following manual steps
    oc rsh dv-engine-0 bash (Only do this if DV caching is enabled) 
    /opt/dv/current/bar/scripts/dv-caching-bar.sh false
    rm -rf /mnt/marker_files/.bar_restored.txt

### Backup documentation
https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/svc-dv/backup-dv.html

### Rollback documentation (also how to list existing backups)
https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/svc-dv/restore-dv.html

#### NOTE: Customers can wrap dvcli.sh in a scheduled job to backup DV on a schedule. 
####       Do keep it in mind that both backup and restore processes stop DV. In other worlds, DV is offline for the duration of backup and restore.

### Known issues and workarounds
https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/svc-dv/known-issues-dv.html

#### Issue 1. DV backup fails with similar error as shown below:

2021-01-14_14.40.42.3N_UTC INFO Use DV init image: in dv-backup-job.yaml

sed: 1: "dv-backup-job.yaml": extra characters at the end of d command

Cause: 

This happens if dv-init-volumes-xxx POD is deleted by either a program or a user. dv-init-volumes-xxx POD is created by the dv-init-volume job. It provides dvcli.sh information where to load the required Docker image containing backup and restore code.

Workaround:

a) Open dvcli.sh in a text editor and find line dv_init_volume_image=$(oc ${EXT_COMMANDS} get pod $dv_init_volume_pod -o jsonpath="{.spec.containers[0].image}"). 

b) Replace it with the following code. Make sure the indents are still correct.

    update_dv_bar_yaml(){
      local yaml_file=$1
      dv_init_volume_job=$(oc ${EXT_COMMANDS} get job | grep -i dv-init-volume | cut -d' ' -f1)
      dv_init_volume_image=$(oc ${EXT_COMMANDS} get job $dv_init_volume_job -o yaml | grep -i image | grep -i v1.5.0.0 | xargs)
      log_info "Use DV init image: $dv_init_volume_image in $yaml_file"
      sed -i '' "s,image: docker-registry.default.svc:5000/zen/dv-init-volume:v1.5.0.0,$dv_init_volume_image,g" $yaml_file
      ec=$?
      check_command_result $ec "$yaml_file updated" "Failed to update $yaml_file"
      }
      
c) Run dvcli.sh with correct parameters to kick off a backup run

#### Issue 2. DV backup pod keeps failing. oc logs dv-backup-xxxx shows a similar directory permission error as shown below

Operation failed: [Errno 13] Permission denied: '/mnt/PV/bar/2021-01-14-19-20-07'

Cause: 

This happens if the SC used to create dv-bar-pvc behaves differently for a create dir call in the backup script. 

Workaround:

a) Delete dv-backup-job.

b) Remove .bar file so DV pods can restart on their own to resume DV operation. This may take up to 30min after the .bar file is removed.
    oc rsh dv-engine-0 bash
    rm -rf /mnt/marker_files/.bar
c) Copy the following file content into a yaml file called dv-test.yaml. Make sure line "image: image-registry.openshift-image-registry.svc:5000/cpd30/dv-init-volume:v1.5.0.0-217" is correct based on the actual registry and image used on the cluster. 

To verify that, run the following commands, the value of dv_init_volume_image is the correct value for the "image: xxxx" line.

    dv_init_volume_job=$(oc ${EXT_COMMANDS} get job | grep -i dv-init-volume | cut -d' ' -f1)
    dv_init_volume_image=$(oc ${EXT_COMMANDS} get job $dv_init_volume_job -o yaml | grep -i image | grep -i v1.5.0.0 | xargs)

d) Create the test pod, run oc create -f dv-test.yaml You see a new dv-test-job-xxxx pod if you run oc get pods | grep -i dv

e) Log in dv-test-job-xxx pod and update /mnt/PV/bar permission
    oc rsh dv-test-job -xxx bash
    sudo chmod 777 /mnt/PV/bar
    
f) Exit dv-test-job-xxx pod, delete dv-test-job, rerun dvcli.sh with correct parameters to kick off a backup process.

           ----------------------------------------------------------------------------
            apiVersion: batch/v1
            kind: Job
            metadata:
            name: dv-test-job
            labels:
            app: dv-test-job
            spec:
                template:
                metadata:
                labels:
                app: dv-test-job
            spec:
                restartPolicy: Never
                hostNetwork: false
                hostPID: false
                hostIPC: false
                securityContext:
                    runAsNonRoot: true
                    runAsUser: 1000322824 # bigsql user
                    serviceAccountName: dv-bar-sa
                containers:
                - name: dv-test-pod
                    image: image-registry.openshift-image-registry.svc:5000/cpd30/dv-init-volume:v1.5.0.0-217
                    imagePullPolicy: Always
                command:
                    - bash
                    - -c
                    - --
                    - tail -f /dev/null
                env:
                    - name: DV_PVC
                    value: "dv-pvc"
                    volumeMounts:
                    - mountPath: /mnt/PV/versioned
                    name: dv-data
                    subPath: "1.5.0"
                    - mountPath: /mnt/PV/versioned/uc_dsserver_shared
                    name: dv-data
                    subPath: uc_dsserver_shared
                    - mountPath: /mnt/PV/versioned/unified_console_data
                    name: dv-data
                    subPath: unified_console_data
                    - mountPath: /mnt/PV/bar
                    name: dv-bar-data
                    subPath: "1.5.0"
                    volumes:
                    - name: dv-data
                    persistentVolumeClaim:
                    claimName: dv-pvc
                    - name: dv-bar-data
                    persistentVolumeClaim:
                    claimName: dv-bar-pvc
