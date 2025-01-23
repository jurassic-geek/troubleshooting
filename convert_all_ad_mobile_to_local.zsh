#!/bin/zsh

################################################################################################
# Created by Jim Quilty | Solutions Engineering | Kandji, Inc.
################################################################################################
# Created on 2024/05/02
################################################################################################
# Tested macOS Versions
################################################################################################
#
#   - 14.4.1
#   - 13.6.6
#   - 12.7.4
#   - 11.7.10
#
################################################################################################
# Software Information
################################################################################################
# This script is designed to modify a computer that is currently bound to an Active Directory.
# When run it will detect if the computer is currently bound and then remove that binding
# if the appropriate option is set.
# The user list will be searched and any normal user accounts will then be tested to see if
# that account is mobile. The account will then be converted to a local account maintaining
# the current cached password.
#
# Portions of this script were based on Rich Trouton's migrate_ad_mobile_account_to_local_account
# script: https://github.com/rtrouton/rtrouton_scripts/blob/main/rtrouton_scripts/
#
# User Configurable variables determine if the computer should be force unbound from AD
# or if the user converted should be added to the local administrators group.
#
# ********* IMPORTANT *********
# Every Active Directory environment is different. This script has been tested using basic
# Active Directory binding and typical Mobile Account setups. Please throughly test this
# script on NON-PRODUCTION computers in your own environment before deploying to
# production computers.
#
################################################################################################
# License Information
################################################################################################
# Copyright 2024 Kandji, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
################################################################################################

# Script Version
VERSION=1.0.2

###################################################################################################
####################################### USER VARIABLES ############################################
###################################################################################################

UNBIND_AD="Yes"             # Options: Yes, No
PROMOTE_TO_ADMIN="No"       # Options: Yes, No

###################################################################################################
############################ FUNCTIONS - DO NOT MODIFY BELOW ######################################
###################################################################################################

# Set logging - Send logs to stdout as well as Unified Log
# Usage: logging "LEVEL" "Message..."
# Use 'log show --process "logger"'to view logs activity.
logging(){
  script_id="convert_mobile"
  timestamp=$(/bin/date +"%m-%d-%Y %H:%M:%S")
  
  echo "${timestamp} ${1}: ${2}"
  /usr/bin/logger "${script_id}: [${1}] ${2}"
}

remove_ad(){
    search_path=$(/usr/bin/dscl /Search -read . CSPSearchPath | /usr/bin/grep Active\ Directory | /usr/bin/sed 's/^ //')

    # Force unbind from Active Directory
    /usr/sbin/dsconfigad -remove -force -u none -p none
    
    # Deletes the Active Directory domain from the custom /Search
    # and /Search/Contacts paths
    /usr/bin/dscl /Search/Contacts -delete . CSPSearchPath "${search_path}"
    /usr/bin/dscl /Search -delete . CSPSearchPath "${search_path}"
    
    # Changes the /Search and /Search/Contacts path type from Custom to Automatic
    /usr/bin/dscl /Search -change . SearchPolicy dsAttrTypeStandard:CSPSearchPath dsAttrTypeStandard:NSPSearchPath
    /usr/bin/dscl /Search/Contacts -change . SearchPolicy dsAttrTypeStandard:CSPSearchPath dsAttrTypeStandard:NSPSearchPath
}

password_migration(){
    # macOS 10.14.4 will remove the the actual ShadowHashData key immediately 
    # if the AuthenticationAuthority array value which references the ShadowHash
    # is removed from the AuthenticationAuthority array. To address this, the
    # existing AuthenticationAuthority array will be modified to remove the Kerberos
    # and LocalCachedUser user values.
    local current_user="${1}"
    local AuthenticationAuthority=$(/usr/bin/dscl -plist . -read /Users/${current_user} AuthenticationAuthority)
    local Kerberosv5=$(echo "${AuthenticationAuthority}" | /usr/bin/xmllint --xpath 'string(//string[contains(text(),"Kerberosv5")])' -)
    local LocalCachedUser=$(echo "${AuthenticationAuthority}" | /usr/bin/xmllint --xpath 'string(//string[contains(text(),"LocalCachedUser")])' -)
    
    # Remove Kerberosv5 and LocalCachedUser
    if [[ ! -z "${Kerberosv5}" ]]; then
        /usr/bin/dscl -plist . -delete /Users/"${current_user}" AuthenticationAuthority "${Kerberosv5}"
    fi
    
    if [[ ! -z "${LocalCachedUser}" ]]; then
        /usr/bin/dscl -plist . -delete /Users/"${current_user}" AuthenticationAuthority "${LocalCachedUser}"
    fi
}

mobile_account_check(){
    local current_user=${1}
    local account_type=$(/usr/bin/dscl . read /Users/"${current_user}" OriginalNodeName 2>/dev/null)
    local uid=$(/usr/bin/dscl . read /Users/"${current_user}" UniqueID 2>/dev/null)

    case "${account_type}" in
        "")
            user_account="LOCAL"
            ;;
        *"Active Directory"*)
            logging "INFO" "Found ${current_user} has a mobile account"
            logging "INFO" "${account_type}"
            logging "INFO" "${uid}"
            user_account="MOBILE"
            ;;
        *)
            logging "ERROR" "Unable to determine user type...."
            exit_status="fail"
            ;;
    esac
}

logging "INFO" "Starting run"
logging "INFO" "Script version ${VERSION}"

# Check for AD binding and unbind desired. 
ad_bound=$(/usr/bin/dscl localhost -list . | /usr/bin/grep "Active Directory")
if [[ "${ad_bound}" == "Active Directory" ]]; then
    logging "INFO" "This machine is bound to Active Directory."
    case "${UNBIND_AD}" in
        Yes)
            remove_ad
            logging "INFO" "AD binding has been removed."
            ;;
        No)
            logging "ERROR" "Active Directory binding is still active."
            logging "ERROR" "Please check if computer is bound via configuration profile."
            ;;
    esac
fi

## Build a list of users
user_list=$(/usr/bin/dscl . -list /Users | /usr/bin/awk '!/^_/ && !/^(root|daemon|nobody|adobe)$/')
declare -a user_array
user_array=($user_list)

# Set initial value for user_account to empty
user_account=""

for user in "${user_array[@]}"; do

    mobile_account_check "${user}"

    if [[ "${user_account}" == "MOBILE" ]]; then  
        logging "INFO" "Converting ${user} to a local account..."
        
        # Remove the account attributes that identify it as an Active Directory mobile account
        /usr/bin/dscl . -delete /users/"${user}" cached_groups
        /usr/bin/dscl . -delete /users/"${user}" cached_auth_policy
        /usr/bin/dscl . -delete /users/"${user}" CopyTimestamp
        /usr/bin/dscl . -delete /users/"${user}" AltSecurityIdentities
        /usr/bin/dscl . -delete /users/"${user}" SMBPrimaryGroupSID
        /usr/bin/dscl . -delete /users/"${user}" OriginalAuthenticationAuthority
        /usr/bin/dscl . -delete /users/"${user}" OriginalNodeName
        /usr/bin/dscl . -delete /users/"${user}" SMBSID
        /usr/bin/dscl . -delete /users/"${user}" SMBScriptPath
        /usr/bin/dscl . -delete /users/"${user}" SMBPasswordLastSet
        /usr/bin/dscl . -delete /users/"${user}" SMBGroupRID
        /usr/bin/dscl . -delete /users/"${user}" PrimaryNTDomain
        /usr/bin/dscl . -delete /users/"${user}" AppleMetaRecordName
        /usr/bin/dscl . -delete /users/"${user}" PrimaryNTDomain
        /usr/bin/dscl . -delete /users/"${user}" MCXSettings
        /usr/bin/dscl . -delete /users/"${user}" MCXFlags
        
        # Migrate password and remove AD-related attributes
        password_migration "${user}"
        
        # Refresh Directory Services
        /usr/bin/killall opendirectoryd
        
        sleep 20
        
        # Check if the de-mobilization was successful
        mobile_account_check "${user}"
        
        if [[ "${user_account}" == "LOCAL" ]]; then
            logging "INFO" "${user} was successfully converted to a local account. Performing cleanup tasks..."
            
            # Clean up and make sure the new local account has correct permissions and groups
            home_dir=$(/usr/bin/dscl . -read /Users/"${user}" NFSHomeDirectory  | /usr/bin/awk '{print $2}')
            if [[ "${home_dir}" != "" ]]; then
                logging "INFO" "Home directory location: ${home_dir}"
                logging "INFO" "Updating home folder permissions for the ${user} account"
                /usr/sbin/chown -R "${user}:staff" "${home_dir}"
            fi
            
            logging "INFO" "Adding ${user} to the staff group on this Mac."
            /usr/sbin/dseditgroup -o edit -a "${user}" -t user staff
            
            # Add admin rights to account migrated if configured
            case "${PROMOTE_TO_ADMIN}" in
                Yes)
                    /usr/sbin/dseditgroup -o edit -a "${user}" -t user admin
                    logging "INFO" "${user} has been successfully promoted to a local administrator"
                    ;;
                No )
                    logging "INFO" "Administrator rights not modified for ${user}"
                    ;;
            esac
            
        else
            logging "ERROR" "Failed to convert ${user} to a local account."
            #Set to exit in failure
            exit_status="fail"
        fi
        
        # Reset user_account value for next run.
        user_account=""
    elif [[ "${user_account}" == "LOCAL" ]]; then
        logging "INFO" "Found ${user} has a local account. Nothing to do..."
    else
        logging "WARNING" "Unable to determine account type of ${user}"
    fi
done

if [[ "${exit_status}" == "fail" ]]; then
    exit 1
else
    logging "INFO" "Finished checking all user accounts."
    exit 0
fi
