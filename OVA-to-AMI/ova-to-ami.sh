#!/bin/bash

set -e  # Exit on any error

# Configuration
OVA_FILE="mrRobot.ova"
INSTANCE_NAME="ova-import-instance"
AMI_NAME="mrrobot-ami-$(date +%Y%m%d-%H%M%S)"
S3_BUCKET="ova-import-bucket-$(date +%Y%m%d-%H%M%S)"
KEY_PAIR_NAME="ova-import-key-$(date +%Y%m%d-%H%M%S)"
SECURITY_GROUP_NAME="ova-import-sg-$(date +%Y%m%d-%H%M%S)"
REGION="us-east-1"  # Change to your preferred region

echo "Starting mrRobot OVA to AMI conversion process..."

# Step 1: Create S3 bucket for OVA file
echo "Creating S3 bucket: $S3_BUCKET"
aws s3 mb s3://$S3_BUCKET --region $REGION

# Step 2: Upload OVA file to S3
echo "Uploading OVA file to S3 bucket"
aws s3 cp ./$OVA_FILE s3://$S3_BUCKET/$OVA_FILE

# Step 3: Create IAM role and policy for VMImport
echo "Creating VMImport service role and policy..."

# Create trust policy for VMImport service
cat > vmimport-trust-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "vmie.amazonaws.com"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "vmimport"
                }
            }
        }
    ]
}
EOF

# Create the VMImport role
VMIMPORT_ROLE_NAME="vmimport"
echo "Checking if vmimport role already exists..."
if aws iam get-role --role-name $VMIMPORT_ROLE_NAME 2>/dev/null; then
    echo "VMImport role already exists, skipping creation"
else
    echo "Creating VMImport role..."
    aws iam create-role --role-name $VMIMPORT_ROLE_NAME \
        --assume-role-policy-document file://vmimport-trust-policy.json
fi

# Create policy for S3 access
cat > vmimport-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetBucketLocation",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET",
                "arn:aws:s3:::$S3_BUCKET/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:ModifySnapshotAttribute",
                "ec2:CopySnapshot",
                "ec2:RegisterImage",
                "ec2:Describe*"
            ],
            "Resource": "*"
        }
    ]
}
EOF

# Attach the policy to the role
aws iam put-role-policy --role-name $VMIMPORT_ROLE_NAME \
    --policy-name "vmimport-s3-access" \
    --policy-document file://vmimport-policy.json

echo "Waiting for IAM role to propagate (30 seconds)..."
sleep 30

# Step 4: Get default VPC ID
echo "Getting default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --region $REGION \
    --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    echo "No default VPC found. Please create a VPC or specify one."
    exit 1
fi

echo "Using VPC: $VPC_ID"

# Step 5: Create Security Group
echo "Creating security group: $SECURITY_GROUP_NAME"
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name $SECURITY_GROUP_NAME \
    --description "Security group for OVA import instance" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'GroupId' \
    --output text)

echo "Security Group created: $SECURITY_GROUP_ID"

# Add SSH rule (port 22)
echo "Adding SSH inbound rule to security group..."
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region $REGION

# Add HTTP rule (port 80)
echo "Adding HTTP inbound rule to security group..."
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region $REGION

# Add HTTPS rule (port 443)
echo "Adding HTTPS inbound rule to security group..."
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0 \
    --region $REGION

# Step 6: Create key pair for EC2 instance
echo "Creating key pair: $KEY_PAIR_NAME"
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
    --region $REGION \
    --query 'KeyMaterial' \
    --output text > ${KEY_PAIR_NAME}.pem
chmod 600 ${KEY_PAIR_NAME}.pem

# Step 7: Find a valid base AMI (Amazon Linux 2)
echo "Finding valid base AMI..."
BASE_AMI=$(aws ec2 describe-images \
    --owners amazon \
    --filters 'Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2' 'Name=state,Values=available' \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --region $REGION \
    --output text)

if [ "$BASE_AMI" = "None" ] || [ -z "$BASE_AMI" ]; then
    echo "Error: Could not find Amazon Linux 2 AMI"
    exit 1
fi

echo "Using base AMI: $BASE_AMI"

# Step 8: Create EC2 instance
echo "Creating EC2 instance for monitoring/management..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $BASE_AMI \
    --count 1 \
    --instance-type t2.micro \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --region $REGION \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance created: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

# Get instance public IP
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Instance is running at: $INSTANCE_IP"

# Step 9: Import OVA as AMI
echo "Starting OVA import process..."

# Create the containers.json file
cat > containers.json << EOF
[
  {
    "Description": "mrRobot OVA",
    "Format": "ova",
    "UserBucket": {
      "S3Bucket": "$S3_BUCKET",
      "S3Key": "$OVA_FILE"
    }
  }
]
EOF

# Start the import
IMPORT_TASK=$(aws ec2 import-image \
    --description "Imported from $OVA_FILE" \
    --disk-containers file://containers.json \
    --region $REGION \
    --query 'ImportTaskId' \
    --output text)

echo "Import task created: $IMPORT_TASK"

# Wait for import to complete
echo "Waiting for import to complete (this may take 30+ minutes)..."
while true; do
    STATUS=$(aws ec2 describe-import-image-tasks \
        --import-task-ids $IMPORT_TASK \
        --region $REGION \
        --query 'ImportImageTasks[0].Status' \
        --output text)
    
    PROGRESS=$(aws ec2 describe-import-image-tasks \
        --import-task-ids $IMPORT_TASK \
        --region $REGION \
        --query 'ImportImageTasks[0].Progress' \
        --output text 2>/dev/null || echo "0")
    
    STATUS_MSG=$(aws ec2 describe-import-image-tasks \
        --import-task-ids $IMPORT_TASK \
        --region $REGION \
        --query 'ImportImageTasks[0].StatusMessage' \
        --output text 2>/dev/null)
    
    echo "[$(date +%H:%M:%S)] Import status: $STATUS | Progress: $PROGRESS%"
    
    if [ "$STATUS" = "completed" ]; then
        echo "Import completed successfully!"
        break
    elif [ "$STATUS" = "deleted" ] || [ "$STATUS" = "deleting" ]; then
        echo "Import was deleted"
        exit 1
    elif [ ! -z "$STATUS_MSG" ] && [ "$STATUS_MSG" != "None" ]; then
        if [[ $STATUS_MSG == *"error"* ]] || [[ $STATUS_MSG == *"failed"* ]] || [[ $STATUS_MSG == *"ClientError"* ]]; then
            echo "Import failed with error: $STATUS_MSG"
            exit 1
        else
            echo "Status message: $STATUS_MSG"
        fi
    fi
    
    sleep 60
done

# Get the AMI ID from import task
AMI_ID=$(aws ec2 describe-import-image-tasks \
    --import-task-ids $IMPORT_TASK \
    --region $REGION \
    --query 'ImportImageTasks[0].ImageId' \
    --output text)

echo "Created AMI: $AMI_ID"

# Step 10: Tag the AMI
echo "Tagging AMI..."
aws ec2 create-tags \
    --resources $AMI_ID \
    --tags Key=Name,Value="$AMI_NAME" Key=Source,Value="OVA-Import" Key=OriginalFile,Value="$OVA_FILE" \
    --region $REGION

# Step 11: Output summary
echo ""
echo "=========================================="
echo "Process completed successfully!"
echo "=========================================="
echo "AMI ID: $AMI_ID"
echo "AMI Name: $AMI_NAME"
echo "Instance ID: $INSTANCE_ID"
echo "Instance IP: $INSTANCE_IP"
echo "Security Group: $SECURITY_GROUP_ID"
echo "Key Pair: $KEY_PAIR_NAME (saved as ${KEY_PAIR_NAME}.pem)"
echo "S3 Bucket: $S3_BUCKET"
echo "Region: $REGION"
echo "=========================================="
echo ""

# List the created AMI for verification
echo "AMI Details:"
aws ec2 describe-images \
    --image-ids $AMI_ID \
    --region $REGION \
    --query 'Images[0].{Name:Name,ImageId:ImageId,State:State,Description:Description,CreationDate:CreationDate}' \
    --output table

echo ""
echo "To connect to the instance:"
echo "ssh -i ${KEY_PAIR_NAME}.pem ec2-user@$INSTANCE_IP"
echo ""
echo "To launch an instance from the imported AMI:"
echo "aws ec2 run-instances --image-id $AMI_ID --instance-type t2.micro --key-name $KEY_PAIR_NAME --security-group-ids $SECURITY_GROUP_ID --region $REGION"
echo ""
echo "Note: The management instance is still running. To terminate it later:"
echo "aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
echo ""
echo "Optional cleanup (run these manually when ready):"
echo "# Delete S3 bucket:"
echo "aws s3 rm s3://$S3_BUCKET --recursive --region $REGION"
echo "aws s3 rb s3://$S3_BUCKET --region $REGION"
echo ""
echo "# Delete temporary files:"
echo "rm -f vmimport-trust-policy.json vmimport-policy.json containers.json"
echo ""
