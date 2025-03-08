#!/bin/bash

# This script is used by certbot for HTTP-01 challenge
# It can be used as both auth and cleanup hook

# Set default values
DOMAIN=""
VALUE=""
ACTION="add"
WEBROOT_PATH=${WEBROOT_PATH:-"/var/www/html"}
WELL_KNOWN_PATH="/.well-known/acme-challenge"

# Parse command line arguments
if [ "$1" == "clean" ]; then
    ACTION="delete"
    shift
fi

# Get domain and validation from environment variables
if [ -n "$CERTBOT_DOMAIN" ]; then
    DOMAIN="$CERTBOT_DOMAIN"
fi

if [ -n "$CERTBOT_VALIDATION" ]; then
    VALUE="$CERTBOT_VALIDATION"
fi

# Check if required variables are set
if [ -z "$DOMAIN" ] || [ -z "$VALUE" ]; then
    echo "Error: CERTBOT_DOMAIN and CERTBOT_VALIDATION environment variables must be set."
    exit 1
fi

# Check if WEBROOT_PATH is accessible
if [ ! -d "$WEBROOT_PATH" ]; then
    echo "Error: WEBROOT_PATH directory ($WEBROOT_PATH) does not exist or is not accessible."
    echo "Please make sure the directory exists and is mounted into the container."
    exit 1
fi

# Create challenge directory if it doesn't exist
CHALLENGE_DIR="$WEBROOT_PATH$WELL_KNOWN_PATH"
if [ ! -d "$CHALLENGE_DIR" ]; then
    echo "Creating challenge directory: $CHALLENGE_DIR"
    mkdir -p "$CHALLENGE_DIR"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create challenge directory: $CHALLENGE_DIR"
        exit 1
    fi
fi

# Full path to the challenge file
CHALLENGE_FILE="$CHALLENGE_DIR/$VALUE"

echo "Domain: $DOMAIN"
echo "Challenge file: $CHALLENGE_FILE"
echo "Value: $VALUE"
echo "Action: $ACTION"

# Perform the HTTP challenge operation
if [ "$ACTION" == "add" ]; then
    # Add challenge file
    echo "Adding HTTP challenge file..."
    echo "$VALUE" > "$CHALLENGE_FILE"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create challenge file: $CHALLENGE_FILE"
        exit 1
    fi
    
    # Set appropriate permissions
    chmod 644 "$CHALLENGE_FILE"
    
    echo "HTTP challenge file created successfully"
    echo "File content: $(cat $CHALLENGE_FILE)"
    
    # For debugging - list content of challenge directory
    echo "Challenge directory content:"
    ls -la "$CHALLENGE_DIR"
    
elif [ "$ACTION" == "delete" ]; then
    # Remove challenge file
    echo "Removing HTTP challenge file..."
    if [ -f "$CHALLENGE_FILE" ]; then
        rm -f "$CHALLENGE_FILE"
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to remove challenge file: $CHALLENGE_FILE"
            exit 1
        fi
        
        echo "HTTP challenge file removed successfully"
    else
        echo "Challenge file not found, nothing to delete"
    fi
fi

echo "HTTP challenge operation completed successfully"
exit 0 