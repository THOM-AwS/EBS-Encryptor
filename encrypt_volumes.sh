#!/bin/bash

#encrypt one ec2 instance:
target_instances=`aws ec2 describe-instances --output text --query "Reservations[*].Instances[*].{instance_Id:InstanceId}" --filter Name=instance-id,Values=`

#encrypt one ec2 instance:
#target_instances=`aws ec2 describe-instances --output text --query "Reservations[*].Instances[*].{instance_Id:InstanceId}" --filter Name=instance-id,Values=MY_INSTANCE_ID`
# get every instance:
# for instance_id in `aws ec2 describe-instances --output text --query "Reservations[*].Instances[*].{instance_Id:InstanceId}"`; 


mykeyarn=arn:aws:kms:ap-southeast-2:MY_ACCOUNT_ID:key/MYKMSKEYID

KMS_KEY_ARN=$mykeyarn

instance_count=0
volume_count=0


previous_power_state=""

persist_instance_state(){
    # expects intance_id and instance state as arguments
    if [ ! -f "$1.txt" ]; then
        echo "$1,$2" > $1.txt
    fi
}

recover_instance_state(){
    # expect instance_id as argument
    previous_power_state=`cat $1 | cut -f2 -d","` 
    rm -rf $1.txt
}

will_shutdown(){
    #expects an instance_id
    # check to see if there is any volumes in on this instance that need to be encrypted
    volumes=`aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=$1 Name=encrypted,Values=true --output json | jq -c '.[][]'`
    
    for volume in $volumes
    do
        is_work_key=$(echo $is_work | jq -r '.KmsKeyId')
        if [[ -z $is_work_key  ||  $KMS_KEY_ARN != $is_work_key ]] 
        then
            return 1
        fi
    done
    return 0
}


check_snapshot(){
    sleep 1
    while [ 1 ]
    do
        snaps_info=`aws ec2 describe-snapshots --snapshot-ids $1`
        snaps_state=$(echo $snaps_info  | jq -r '.Snapshots[0].State')
        snapshot_progress=$(echo $snaps_info | jq -r '.Snapshots[].Progress')
        if [ $snaps_state == "pending" ]
        then
            echo "    Working 10 seconds...."
            sleep 10
        elif [ $snaps_state == "error" ]
        then
                echo "error returned when $2... exiting"
                exit 1
        elif [ $snaps_state == "completed" ]
        then    
                echo "        Completed $2 on $1"
                #echo "1 " $1, "2 " $2, "3 " $snaps_state, "4 " $snaps_info
                return
        else 
            echo "There was an unexpected response with SNAPSHOT COPY $1 on $2. exiting...."
            echo ">>>> UNKOWN ERROR >>>>"
            echo "Object: " $1, "Operation: " $2, "Snap State: " $snaps_state, "Snap Info: " $snaps_info
            exit 10
        fi
        
    done
}

# deleting | in-use | available | creating | detached
check_vol(){
    while [ 1 ]
    do
        vols_info=`aws ec2 describe-volumes --volume-ids $1`
        vols_state=$(echo $vols_info  | jq -r '.Volumes[0].State')
        if [ $vols_state == "creating" ]
        then
            echo "    Volume Still Attached"
            sleep 1
        elif [ $vols_state == "error" ]
        then
                echo "error returned when $2 on $1... exiting"
                exit 1
        elif [ $vols_state == "available" ]
        then    
                echo "        Completed $2 on $1"
                #echo "1 " $1, "2 " $2, "3 " $vols_state, "4 " $vols_info
                return
        else 
            echo "There was an unexpected response with VOLUME COPY $1 on $2. exiting...."
            echo ">>>> UNKOWN ERROR >>>>"
            echo "Object: " $1, "Operation: " $2, "Vols State " $vols_state, "Vols Info: " $vols_info
            exit 10
        fi
        
    done
}

# deleting | in-use | available | creating | detached
check_vol_remove(){
    while [ 1 ]
    do
        vols_remove_info=`aws ec2 describe-volumes --volume-ids $1`
        vols_remove_state=$(echo $vols_remove_info  | jq -r '.Volumes[0].State')
        if [ $vols_remove_state == "attached" ]
        then
            echo "    Volume Still Attached...."
            echo "        Waiting...."
            sleep 1
        elif [ $vols_remove_state == "detaching" ]
        then 
            echo ""
            echo "volume detaching..."
            sleep 1
        elif [ $vols_remove_state == "error" ]
        then
            echo "error returned when $2 on $1... exiting"
            exit 1
        elif [ $vols_remove_state == "available" ]
        then    
            echo "        Completed $2 on $1"
            #echo "1 " $1, "2 " $2, "3 " $vols_state, "4 " $vols_info
            return
        else 
            echo "There was an unexpected response with VOLUME COPY $1 on $2. exiting...."
            echo ">>>> UNKOWN ERROR >>>>"
            echo "Object: " $1, "Operation: " $2, "Vols Remove State: " $vols_remove_state, "Vols Remove Info " $vols_remove_info
            exit 10
        fi
        
    done

}
for instance_id in $target_instances; 

# START loop to instances
do 

    # will_shutdown $instance_id
    # if [ $? -eq 0 ];then
    #     break
    # fi

    # get the data:
    # describe instances and drop the data in to the variable
    instance_data=`aws ec2 describe-instances --instance-id $instance_id --query "Reservations[*].Instances[*].{AZ:Placement.AvailabilityZone,Instance:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,BlockDevice:BlockDeviceMappings[].DeviceName}" --output json | jq '.[0][0]'`
    
    
    
    # assign some instance varibles to use later
    instance_name=$(echo $instance_data | jq '.Name')
    instance_status=$(echo $instance_data | jq -r ".Status")
    instance_az=$(echo $instance_data | jq -r ".AZ")
    instance_device=$(echo $instance_data | jq -r ".BlockDevice")
    echo "Current KMS Key to apply = $KMS_KEY_ARN"

    persist_instance_state $instance_id $instance_status
    
    # do the stuff:

    # take note of the state of the instance
    
    if [ $instance_status == "running" ];
    then
        echo "The following instance is running and will be stopped now: "
        echo ""
        echo "waiting for the instance to stop...."
        echo ""
        aws ec2 stop-instances --instance-ids $instance_id
        aws ec2 wait instance-stopped --instance-ids $instance_id
        echo "this instance is now:"
        aws ec2 describe-instances --output json --query "Reservations[*].Instances[*]" --filter Name=instance-id,Values=$instance_id | jq -r '.[0][0].State.Name'
        echo ""
        echo "Instance is stopped, and will be restarted after changeover."
        echo ""
    else   
        echo "this instance is now:"
        aws ec2 describe-instances --output json --query "Reservations[*].Instances[*]" --filter Name=instance-id,Values=$instance_id | jq -r '.[0][0].State.Name'
        echo ""
        echo "Instance is stopped, and will be left stopped."
        echo ""

    fi

    # assign some volume variables to use later
    echo "Instance Name = $instance_name"
    echo "Instance ID = $instance_id"
    echo "Instance AZ = $instance_az"
    echo "Instance Status = $instance_status"

    # describe the volumes and drop the data into a variable
    volume_data=`aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=$instance_id --query "Volumes[*].{Encrypted:Encrypted,AvailabilityZone:AvailabilityZone,VolumeType:VolumeType,State:State,Size:Size,KmsKeyId:KmsKeyId,Device:Attachments[].Device,VolumeId:Attachments[].VolumeId,Tags:Tags}" --output json  | jq -c '.[]'`

    # START loop to volumes
    for volume in $volume_data
    do
        # assign variables for use
        volume_id=$(echo $volume | jq -r '.VolumeId[0]') 
        volume_encryption=$(echo $volume | jq -r ".Encrypted")
        volume_AvailabilityZone=$(echo $volume | jq -r ".AvailabilityZone")
        volume_type=$(echo $volume | jq -r ".VolumeType")
        volume_state=$(echo $volume | jq -r ".State")
        volume_size=$(echo $volume | jq -r ".Size")
        volume_path=$(echo $volume | jq -r ".Device[0]") 
        volume_tags=`aws ec2 describe-tags --filters "Name=resource-id,Values=$volume_id" | jq -c '.Tags[]'`
        volume_keys=$(echo $volume | jq -r ".KmsKeyId")
        
        TAGS_COMPLETION=""
        tags=""

        if [[ -n $volume_tags ]]; then    
            
            for tag in $volume_tags
            do  
                value=$(echo $tag | jq '.Value')
                key=$(echo $tag | jq '.Key')
                if [ -z `echo $key | sed -n '/^"aws/p'` ]
                then
                    tags=$tags"{Key=$key,Value=$value}"    
                fi
            done
            tags=$(echo $tags | sed -s 's/}{/},{/g' )
            TAGS_COMPLETION=" --tag-specifications ResourceType=snapshot,Tags=[$tags]"
        fi 
        
        echo "    Volume Id: $volume_id"
        echo "    Volume Encrypted: $volume_encryption"
        echo "    Volume Availablity Zone: $volume_AvailabilityZone"
        echo "    Volume Type: $volume_type"
        echo "    Volume State: $volume_state"        
        echo "    Volume Size (Gb): $volume_size"
        echo "    Volume Path: $volume_path"
        echo "    Volume KMS Key: $volume_keys"
        echo "    Volume Tags: $tags"

        if [ $volume_keys == $KMS_KEY_ARN ]
        then
            echo ""
            echo "    This Volume is already Encrypted with the Correct KMS Key. looking at the next volume or instance."
            echo ""
            break
        else
            echo ""
            echo "    Volume is not Encrypted, or has the wrong key. Continuing."
            echo ""
        fi

        echo $volume_keys
        echo $KMS_KEY_ARN

        # create the snapshot & get the snapshot ID
        snapshot_info=`aws ec2 create-snapshot --volume-id $volume_id --description "Unencrypted Snapshot from $volume_id" $TAGS_COMPLETION`

        echo $snapshot_info;
        
        
        echo ""
        echo "      Creating Volume Snapshot."
        echo ""
        echo "_____________________________________________________"
        echo " This snapshot: $snapshot_info"
        echo ; echo 
        unencrypted_snapshot_id=$(echo $snapshot_info | jq -r '.SnapshotId')
        
        echo "    SnapId: $unencrypted_snapshot_id"
        #check the status of the snapshot from the volume before continuing
        check_snapshot $unencrypted_snapshot_id "Create the snapshot from the volume"
        echo ""
        echo "        Unencrypted Snap Created."
        echo "_____________________________________________________"

        echo ""
        echo "Creating Encrypted snapshot from $unencrypted_snapshot_id"
        # copy to encrypted snapshot
        encrypted_snapshot_info=`aws ec2 copy-snapshot --source-snapshot-id $unencrypted_snapshot_id --source-region ap-southeast-2 --destination-region ap-southeast-2 --description "Encrypted Snapshot from $volume_id" --encrypted --kms-key-id $KMS_KEY_ARN`
        echo $encrypted_snapshot_info
        #get the ID
        encrypted_snapshot_id=$(echo $encrypted_snapshot_info | jq -r '.SnapshotId')

        #wait for the copy to finish
        check_snapshot $encrypted_snapshot_id "Copying snapshot with encryption"
        echo ""
        echo "        Encrypted Snap Created."
        echo "....................................................."

        # create a volume
        new_volume=`aws ec2 create-volume --volume-type $volume_type --snapshot-id $encrypted_snapshot_id --availability-zone $volume_AvailabilityZone --encrypted --kms-key-id $KMS_KEY_ARN` 

        # detach old
        detached_volume=`aws ec2 detach-volume --volume-id $volume_id`
        
        #wait for the old volume to detach
        detached_volume_state=$(echo $detached_volume | jq -r '.State')
        check_vol_remove $volume_id "waiting for volume to detach" $detached_volume_state
        
        echo ""
        echo "        Unencrypted Volume Detached."
        echo "_____________________________________________________"

        new_volume_id=$(echo $new_volume | jq -r '.VolumeId')
        check_vol $new_volume_id "create new volume from snapshot"

        # attach new
        aws ec2 attach-volume --volume-id $new_volume_id --instance-id $instance_id --device $volume_path

        echo ""
        echo "        Encrypted Volume Attached."
        echo "....................................................."

        # put machine to previous state
        
        
        volume_count=$((volume_count+1))
    done 


    recover_instance_state $instance_id

    if [ $previous_power_state == "running" ]
    then
        echo "Restarting the instance: $instance_id"
        aws ec2 start-instances --instance-ids $instance_id
        aws ec2 wait instance-running --instance-ids $instance_id
        echo "this instance is now:"
        aws ec2 describe-instances --output json --query "Reservations[*].Instances[*]" --filter Name=instance-id,Values=$instance_id | jq -r '.[0][0].State.Name'
    fi



instance_count=$((instance_count+1))
done
echo ""
echo ""
echo ======================================================
echo ""
#echo "              Instances changed: $"
echo "              Instance Count is: $instance_count"
echo "              Volume Count is : $volume_count"
echo ""
echo ======================================================
