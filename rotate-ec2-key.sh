#!/usr/bin/env bash

# ================================================================
# === DESCRIPTION
# ================================================================
#
# Summary: This script rotates the root ssh key on an EC2 instance
#
# Version: 1.0.0
#
# Tested platforms:
#    - CoreOS (ignition must be used instead of cloud-init to persist key rotation. See: https://coreos.com/ignition/docs/latest)
#    - Ubuntu, Amazon Linux
#
# Command-line arguments:
#    - See the 'PrintHelp' function below for command-line arguments. Or run this script with the --help option.
#
# Legal stuff:
#    - Copyright (c) 2015 Jake Bennett
#    - Licensed under the MIT License - https://opensource.org/licenses/MIT


# ================================================================
# === FUNCTIONS
# ================================================================

function PrintHelp() {
    echo "usage: $__base.sh [options...] "
    echo "options:"
    echo " -s --ssh-key-file        Path to EC2 private ssh key file for the key to be replaced. Required."
    echo " -k --new-ssh-key-file    Path to EC2 private ssh key file for the new ssh key. Required."
    echo " -p --new-ssh-pub-file    Path to EC2 public ssh key file for the new ssh key. Required."
    echo " -h --host                IP address or DNS name for the EC2 instance. Required."
    echo " -a --aws-key-file        The file for the .csv access key file for an AWS administrator. Optional. The AWS administrator"
    echo "                          must have the rights to create tags for EC2 instances. The script expects the .csv format "
    echo "                          used when you dowload the key from IAM in the AWS console. If you don't specify a key file,"
    echo "                          the default credentials in ~/.aws/credentials will be used."
    echo " -u --user                Root/admin user for the EC2 instance. Optional. The default value is 'ec2-user' (for the Amazon Linux AMI)."
    echo " -j --json                A file to send JSON output to. Optional."
    echo "    --help                Prints this help message"
}

function ConfigureAwsCli() {
# Configure the AWS command-line tool with the proper credentials

    if [[ ! -z "$AWS_KEY_FILE" ]] ; then
        echo "Using the AWS administrator key file specified."

        AWS_ACCESS_KEY_ID=$(awk -F ',' 'NR==2 {print $2}' "$AWS_KEY_FILE")
        AWS_SECRET_ACCESS_KEY=$(awk -F ',' 'NR==2 {print $3}' "$AWS_KEY_FILE")

        # Configure temp profile
        aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
        aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    fi

}

function VerifySSHKey() {
# Test the old key first to make sure it works

    echo "Testing the current private EC2 key passed in the command line..."
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -q -i "$OLD_KEY_FILE" "$EC2_USER@$EC2_HOST" who && RETURN_CODE=$? || RETURN_CODE=$?

    if [ "$RETURN_CODE" -ne 0 ] ; then
        >&2 echo "Unable to connect via SSH using the EC2 key '$OLD_KEY_FILE'"
        >&2 echo "Stopping. No keys were rotated."
        exit 5
    else
        echo "EC2 key '$OLD_KEY_FILE' works."
    fi

}

function VerifyAWSPermissions() {
# Verify that the credentials used for the AWS CLI have the rights to update tags on the EC2 instance.

    # Get instance-id from the AWS EC2 meta-data.
    echo "Getting EC2 meta-data..."
    INSTANCE_ID=$(ssh -o StrictHostKeyChecking=no -q -i "$OLD_KEY_FILE" "$EC2_USER@$EC2_HOST" "curl -s http://169.254.169.254/latest/meta-data/instance-id")
    echo "EC2 instance-id: $INSTANCE_ID"

    # Test to make sure we have rights to update the tags for this instance. Otherwise, stop.
    echo "Verifying that the AWS CLI credentials are allowed to update tags on the EC2 instance..."
    # Get the current tag value for the
    aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" > ec2_tags

    TAG_LINE=$(sed -n '\|RotatedKey|=' ec2_tags)

    # Check if we found a tag specifying EC2 SSH key
    if [[ -z "$TAG_LINE" ]]; then
        # The ssh key tag doesn't existing yet on this instance
        TAG_VALUE=""
    else
        TAG_LINE=$((TAG_LINE-1))
        TAG_VALUE=$(awk -F ':' 'FNR==MY_LINE {print substr($2,3) }' MY_LINE=$TAG_LINE ec2_tags)
        TAG_VALUE=$(echo "$TAG_VALUE" | cut -d "\"" -f1)
    fi
    rm ec2_tags

    # Make small update to tag for testing purposes, and then revert it back
    aws ec2 create-tags --resources "$INSTANCE_ID" --tags Key=RotatedKey,Value="$TAG_VALUE "
    aws ec2 create-tags --resources "$INSTANCE_ID" --tags Key=RotatedKey,Value="$TAG_VALUE"
    echo "Verified. The AWS credentials have permission to update tags."

}

# ================================================================
# === INITIALIZATION
# ================================================================

# Exit if there is an error in the script. Get last error for piped commands
set -o errexit
set -o pipefail
#set -o xtrace

# Set magic variables
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__root="$(cd "$(dirname "${__dir}")" && pwd)" # <-- change this
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename ${__file} .sh)"


# ======================================================
# === PARSE COMMAND-LINE OPTIONS
# ======================================================

OLD_KEY_FILE=
EC2_HOST=
EC2_USER=ec2-user
AWS_KEY_FILE=
JSON_OUTPUT_FILE=

# Check if any arguments were passed. If not, print an error
if [ $# -eq 0 ]; then
    PrintHelp
    exit 2
fi

# Loop through the command-line options
while [ "$1" != "" ]; do

    case "$1" in
        -s | --ssh-key-file) shift
                      OLD_KEY_FILE="$1"
                      ;;
        -k | --new-ssh-key-file) shift
                      NEW_PRIVATE_KEY_FILE="$1"
                      ;;
        -p | --new-ssh-pub-file) shift
                      NEW_PUBLIC_KEY_FILE="$1"
                      ;;
        -h | --host)  shift
                      EC2_HOST="$1"
                      ;;
        -u | --user)  shift
                      EC2_USER="$1"
                      ;;
        -a | --aws-key-file)  shift
                      AWS_KEY_FILE="$1"
                      ;;
        -j | --json)  shift
                      JSON_OUTPUT_FILE="$1"
                      ;;
        --help)       PrintHelp
                      exit 0
                      ;;
        *)            >&2 echo "error: invalid option: '$1'"
                      PrintHelp
                      exit 3
    esac

    # Shift all the parameters down by one
    shift

done

# Make sure that all the required arguments were passed into the script
if [ -z "$OLD_KEY_FILE" ] ; then
    >&2 echo "Missing --ssh-key-file"
    PrintHelp
    exit 2
fi

if [ -z "$EC2_HOST" ] ; then
    >&2 echo "Missing --host"
    PrintHelp
    exit 2
fi

if [ -z "$NEW_PRIVATE_KEY_FILE" ] ; then
    >&2 echo "Missing --new-ssh-key-file"
    PrintHelp
    exit 2
fi

if [ ! -f "$NEW_PRIVATE_KEY_FILE" ] ; then
    >&2 echo "Unable to find $NEW_PRIVATE_KEY_FILE"
    exit 2
fi

if [ -z "$NEW_PUBLIC_KEY_FILE" ] ; then
    >&2 echo "Missing --new-ssh-pub-file"
    PrintHelp
    exit 2
fi

if [ ! -f "$NEW_PUBLIC_KEY_FILE" ] ; then
    >&2 echo "Unable to find $NEW_PRIVATE_KEY_FILE"
    exit 2
fi


# ======================================================
# === MAIN SCRIPT
# ======================================================

echo ""
echo "Starting key rotation process..."

# Do initial housekeeping and verification that we have the proper rights to rotate keys
ConfigureAwsCli
VerifySSHKey
VerifyAWSPermissions

# Check the Linux distro. If it's CoreOS, we need to do some special processing.
PLATFORM=$(ssh -o StrictHostKeyChecking=no -q -i "$OLD_KEY_FILE" "$EC2_USER@$EC2_HOST" "uname -a")
echo "Platform: $PLATFORM"

# Display new key info
NEW_KEY_NAME=$(basename "$NEW_PRIVATE_KEY_FILE")
echo "---------------------------------------"
echo "New private key file: $NEW_PRIVATE_KEY_FILE"
echo "New public key file: $NEW_PRIVATE_KEY_FILE"
echo "---------------------------------------"
echo ""

# Test the new key: Add the new key to the authorized keys on the instance, update a test file, and re-log in
# with the new key to retrieve the test value
echo "Testing new key..."
echo $(cat "$NEW_PUBLIC_KEY_FILE") | ssh -o StrictHostKeyChecking=no -q -i "$OLD_KEY_FILE" "$EC2_USER@$EC2_HOST" \
    "cat >> ~/.ssh/authorized_keys"

TEST_VALUE="Testing 123"
echo "$TEST_VALUE" | ssh -o StrictHostKeyChecking=no -q -i "$OLD_KEY_FILE" "$EC2_USER@$EC2_HOST" "cat > ~/.rotation_test_file"
NEW_TEST_VALUE=$(ssh -o StrictHostKeyChecking=no -q -i "$NEW_PRIVATE_KEY_FILE" "$EC2_USER@$EC2_HOST" "cat ~/.rotation_test_file")

if [ "$NEW_TEST_VALUE" != "$TEST_VALUE" ] ; then
    >&2 echo "Test with the new key failed. Stopping."
    exit 4
fi

echo "Test successful. Removing old key..."

# Get a sed-search-safe version of the public key that escapes forward slashes contained in the key
OLD_PUBLIC_KEY=$(ssh-keygen -y -f $OLD_KEY_FILE)
OLD_PUBLIC_KEY=$(echo "$OLD_PUBLIC_KEY" | sed 's/\//\\\//g')

 # Remove the old key from ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=no -q -i "$NEW_PRIVATE_KEY_FILE" "$EC2_USER@$EC2_HOST" \
        "sed -i \"/$OLD_PUBLIC_KEY/d\" ~/.ssh/authorized_keys"

# Test again with new key
echo "Re-testing new key..."
NEW_TEST_VALUE=$(ssh -o StrictHostKeyChecking=no -q -i "$NEW_PRIVATE_KEY_FILE" "$EC2_USER@$EC2_HOST" "cat ~/.rotation_test_file")

if [ "$NEW_TEST_VALUE" != "$TEST_VALUE" ] ; then
    >&2 echo "WARNING: Second test with the new key failed. Try accessing EC2 instance immediately."
    exit 4
fi

echo "Second test successful. Keys have been rotated. Please keep your new key files in a secure location."

# Cleanup the temp file used for testing
ssh -o StrictHostKeyChecking=no -q -i "$NEW_PRIVATE_KEY_FILE" "$EC2_USER@$EC2_HOST" "rm -f ~/.rotation_test_file"

# Update the EC2 instance to include a tag with the key name
echo "Updating the instance tag to include the key name..."
aws ec2 create-tags --resources "$INSTANCE_ID" --tags Key=RotatedKey,Value="$NEW_KEY_NAME"

# Print the JSON file if requested
if [ ! "$JSON_OUTPUT_FILE" == "" ]; then
    echo "Outputing JSON to $JSON_OUTPUT_FILE..."
    printf '
    {
        "KeyName":"%s",
        "Host": "%s",
        "InstanceId":"%s",
        "PrivateKeyFile":"%s",
        "PublicKeyFile": "%s"
    }\n' "$NEW_KEY_NAME" "$EC2_HOST" "$INSTANCE_ID" "$__dir/$NEW_PRIVATE_KEY_FILE" "$__dir/$NEW_PUBLIC_KEY_FILE" > "$JSON_OUTPUT_FILE"
fi

echo "Rotation complete."

