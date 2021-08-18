# EBS-Encryptor
encrypt your ebs volumes that are already in use

Your volume names should not contain spaces, or this process will fail. 

This BASH script can be run against a specific EC2 instance ID, or agains the whole account. Takes an instance ID and a KMS key as arguments at the top of the script. 